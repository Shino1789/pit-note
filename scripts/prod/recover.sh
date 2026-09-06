#!/bin/bash

# ==================================================
# 本番β環境 復旧スクリプト
#
# infra/terraform/aws を apply し、GitHub Actions deploy.yml で
# ECS/ECRへのデプロイを行い、Vercelを再開して疎通確認まで行う。
#
# 前提: scripts/prod/shutdown.sh でdestroyした状態、または
#       AWSリソースが誤って削除された状態からの復旧を想定する。
#
# 実行順序（docs/operations/recovery.mdの手順に対応。
# JWT Secret再投入は「ECSがJWT未設定のまま起動を試みる事態」を
# 避けるため、CD実行より前＝terraform apply直後に前倒ししている。
# 理由はdocs/operations/recovery.md参照）:
#    1. AWSアカウント/リージョン確認
#    2. Terraform backend確認
#    3. terraform init
#    4. terraform plan
#    5. destroy/replaceが含まれていないことを確認
#    6. ユーザー確認
#    7. terraform apply
#    8. JWT Secret再投入（値が未設定の場合のみ。既存値がある場合はスキップ）
#    9. AWSリソース確認（ECS一時的unhealthyは想定内）
#   10. GitHub Actions deploy.yml を workflow_dispatch（--ref main）
#   11. CD完了・success確認
#   12. ECSロールアウト確認
#   13. ALB Target Health確認
#   14. ALB直接health確認（DNSを経由せず、ALBのDNS名に直接アクセス）
#   15. Route53 Alias確認（差分があれば手動対応として停止）
#   16. API health確認（カスタムドメイン経由）
#   17. Vercel resume ※12〜16すべてが正常な場合のみ実行する
#       （AWS側の復旧を確認しないまま一般公開しないための安全条件）
#   18. Frontend health確認
#   19. 最終terraform plan（No changes期待）
#
# 使い方:
#   ./scripts/prod/recover.sh                    # 通常実行
#   ./scripts/prod/recover.sh --force-jwt-reset  # 既存JWT値があっても再生成する
# ==================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

FORCE_JWT_RESET=false
for arg in "$@"; do
  case "$arg" in
    --force-jwt-reset) FORCE_JWT_RESET=true ;;
    *) die "不明な引数です: $arg" "使い方: ./scripts/prod/recover.sh [--force-jwt-reset]" ;;
  esac
done

require_commands aws terraform jq curl vercel gh git openssl

# --------------------------------------------------
# 1. AWSアカウント/リージョン確認
# --------------------------------------------------
check_aws_identity

# --------------------------------------------------
# 2. Terraform backend確認 / 3. terraform init
# --------------------------------------------------
log_step "Terraform backend確認"
check_terraform_backend "$TF_AWS_DIR" "s3"
( cd "$TF_AWS_DIR" && terraform init -input=false )

# --------------------------------------------------
# 4. terraform plan
# --------------------------------------------------
log_step "terraform plan"
APPLY_PLAN_FILE="$TF_AWS_DIR/.prod-recover.apply.tfplan"
( cd "$TF_AWS_DIR" && terraform plan -no-color -input=false -out="$APPLY_PLAN_FILE" )
# ・-no-colorを付けないと、terraform showの出力にANSI色コードが
#   混ざりgrepの行頭マッチ（^Plan:等）が一致しなくなるため必須
plan_summary=$( (cd "$TF_AWS_DIR" && terraform show -no-color "$APPLY_PLAN_FILE") | grep -E "^Plan:|^No changes" || echo "Plan: (取得失敗)")
echo ""
echo "  $plan_summary"

# --------------------------------------------------
# 5. destroy/replaceが含まれていないことを確認
# --------------------------------------------------
if [[ "$plan_summary" == *"to destroy"* ]] && [[ "$plan_summary" != *"0 to destroy"* ]]; then
  die "planにdestroy/replaceが含まれています。想定外の変更です。" \
    "terraform show \"$APPLY_PLAN_FILE\" の内容を確認し、コードとAWSの実状態を精査してください。"
fi

# --------------------------------------------------
# 6. ユーザー確認 → 7. terraform apply
# --------------------------------------------------
log_step "terraform apply確認"
read -r -p "上記planでAWSリソースを作成/更新します。続行しますか？ [yes/no]: " answer
if [ "$answer" != "yes" ]; then
  log_info "キャンセルしました"
  rm -f "$APPLY_PLAN_FILE"
  exit 0
fi

( cd "$TF_AWS_DIR" && terraform apply -no-color -input=false "$APPLY_PLAN_FILE" )
rm -f "$APPLY_PLAN_FILE"
log_info "terraform applyが完了しました"

# --------------------------------------------------
# 8. JWT Secret再投入
# ・値が未設定（バージョンが1つも無い）の場合のみ自動生成する
# ・--force-jwt-resetで既存値があっても強制再生成できる
# ・値は一切echo/logしない
# --------------------------------------------------
log_step "JWT Secret確認"

has_jwt_version=$(aws secretsmanager describe-secret \
  --secret-id "$JWT_SECRET_ID" \
  --query 'length(VersionIdsToStages)' --output text 2>/dev/null || echo "0")

if [ "$has_jwt_version" = "0" ] || [ "$FORCE_JWT_RESET" = true ]; then
  log_info "JWT Secretの値を新規生成して投入します（既存のリフレッシュトークンは無効化されます）"
  jwt_value=$(openssl rand -base64 64 | tr -d '\n')
  put_secret_value_safely "$JWT_SECRET_ID" "$(jq -n --arg v "$jwt_value" '{JWT_SECRET_KEY: $v}')"
  unset jwt_value
  log_info "JWT Secretを投入しました（値はログに出力していません）"
else
  log_info "JWT Secretには既に値が設定されているため、再生成をスキップします（--force-jwt-resetで強制可能）"
fi

# --------------------------------------------------
# 9. AWSリソース確認
# ・この時点ではECRにimageが無いため、ECS Taskは一時的に
#   unhealthy/起動失敗になる。これは想定内の状態であり、
#   次のCDでイメージがpushされ次第正常化する
# --------------------------------------------------
log_step "AWSリソース状態確認（この時点でECSがunhealthyでも想定内）"
aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0].{status:status,runningCount:runningCount,desiredCount:desiredCount,taskDefinition:taskDefinition}' \
  --output table || true

# --------------------------------------------------
# 10. GitHub Actions deploy.yml を workflow_dispatch
# --------------------------------------------------
log_step "GitHub Actions CD実行（deploy.yml, --ref main）"

run_output=$(gh workflow run deploy.yml --ref main 2>&1) || die "workflow_dispatchの実行に失敗しました: $run_output" \
  "GitHub CLIの認証状態（gh auth status）を確認してください。"
echo "$run_output"

log_info "CDの起動を検知しています..."
run_id=""
for _ in $(seq 1 10); do
  sleep 3
  run_id=$(gh run list --workflow=deploy.yml --limit 1 --json databaseId,event,createdAt \
    --jq '.[0].databaseId' 2>/dev/null || echo "")
  [ -n "$run_id" ] && break
done

if [ -z "$run_id" ]; then
  die "実行中のワークフローを特定できませんでした" \
    "GitHub Actions画面（gh run list --workflow=deploy.yml）で手動確認してください。"
fi

# --------------------------------------------------
# 11. CD完了・success確認
# --------------------------------------------------
log_info "GitHub Actions run #$run_id を監視します（最大30分）"
# ・gh run view の一時的な失敗でスクリプト全体を落とさないよう、
#   `|| true` で吸収し、次のポーリングで再試行する
run_status=""
for _ in $(seq 1 120); do
  run_status=$(gh run view "$run_id" --json status --jq '.status' 2>/dev/null || echo "")
  [ "$run_status" = "completed" ] && break
  sleep 15
done

if [ "$run_status" != "completed" ]; then
  die "GitHub Actions runの完了を30分待っても確認できませんでした（run #$run_id）" \
    "gh run view $run_id で状況を確認してください。長時間かかっている場合は原因調査が必要です。"
fi

run_conclusion=$(gh run view "$run_id" --json conclusion --jq '.conclusion' 2>/dev/null || echo "unknown")
if [ "$run_conclusion" != "success" ]; then
  die "GitHub Actions CDが失敗しました（conclusion: $run_conclusion）" \
    "gh run view $run_id --log-failed でログを確認し、原因を解消してから ./scripts/prod/recover.sh を再実行してください。"
fi
log_info "GitHub Actions CDが成功しました（run #$run_id）"

# --------------------------------------------------
# 12. ECSロールアウト確認
# ・以降、Vercel resume（17.）の可否判定に使う health_ok を
#   ここから積み上げていく（AWS側が正常と確認できるまでは
#   一般公開＝Vercel resumeを行わない設計）
# --------------------------------------------------
log_step "ECSロールアウト確認"
health_ok=true

ecs_json=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0].{status:status,runningCount:runningCount,desiredCount:desiredCount,taskDefinition:taskDefinition,rolloutState:deployments[0].rolloutState}' \
  --output json)
echo "$ecs_json" | jq -r '
  "  status         : \(.status)",
  "  runningCount   : \(.runningCount)",
  "  desiredCount   : \(.desiredCount)",
  "  taskDefinition : \(.taskDefinition)",
  "  rolloutState   : \(.rolloutState)"
'

ecs_running=$(echo "$ecs_json" | jq -r '.runningCount')
ecs_desired=$(echo "$ecs_json" | jq -r '.desiredCount')
if [ "$ecs_running" != "$ecs_desired" ] || [ "$ecs_running" = "0" ]; then
  log_warn "ECSのrunningCountがdesiredCountと一致していません"
  health_ok=false
fi

# --------------------------------------------------
# 13. ALB Target Health確認
# --------------------------------------------------
log_step "ALB Target Health確認"
tg_arn=$(aws elbv2 describe-target-groups --names "$TARGET_GROUP_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
tg_states=$(aws elbv2 describe-target-health --target-group-arn "$tg_arn" \
  --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)
echo "  $tg_states"

if ! echo "$tg_states" | grep -qw "healthy"; then
  log_warn "ALB Target Groupにhealthyなターゲットがありません"
  health_ok=false
fi

# --------------------------------------------------
# 14. ALB直接health確認（DNSを経由しない）
# --------------------------------------------------
log_step "ALB直接health確認"
alb_dns_name=$( (cd "$TF_AWS_DIR" && terraform output -raw alb_dns_name) )
alb_zone_id=$( (cd "$TF_AWS_DIR" && terraform output -raw alb_zone_id) )
alb_direct_code=$(curl -s -o /dev/null -w "%{http_code}" -k \
  -H "Host: ${ROUTE53_RECORD_NAME}" "https://${alb_dns_name}${API_HEALTH_PATH}" || echo "000")
echo "  https://${alb_dns_name}${API_HEALTH_PATH} (Host: ${ROUTE53_RECORD_NAME}) -> HTTP $alb_direct_code"

if [ "$alb_direct_code" != "200" ]; then
  log_warn "ALB経由の直接ヘルスチェックが200以外です。ECS/ALBの状態を確認してください。"
  health_ok=false
fi

# --------------------------------------------------
# 15. Route53 Alias確認
# ・ALBが再作成された場合のみDNS名が変わる。差分があれば手動対応
#   （DNSの誤設定は影響が大きいため自動更新はしない）
# --------------------------------------------------
log_step "Route53 Alias確認"

hosted_zone_id=$(aws route53 list-hosted-zones-by-name --dns-name "$FRONTEND_DOMAIN" \
  --query "HostedZones[?Name=='${FRONTEND_DOMAIN}.'].Id | [0]" --output text 2>/dev/null | sed 's|/hostedzone/||')

current_alias_dns=""
if [ -n "$hosted_zone_id" ] && [ "$hosted_zone_id" != "None" ]; then
  current_alias_dns=$(aws route53 list-resource-record-sets --hosted-zone-id "$hosted_zone_id" \
    --query "ResourceRecordSets[?Name=='${ROUTE53_RECORD_NAME}.'].AliasTarget.DNSName | [0]" --output text 2>/dev/null)
fi

normalized_current=$(echo "$current_alias_dns" | sed 's/^dualstack\.//; s/\.$//')

if [ -z "$current_alias_dns" ] || [ "$current_alias_dns" = "None" ]; then
  log_warn "Route53レコード（$ROUTE53_RECORD_NAME）が見つかりませんでした。手動で確認してください。"
elif [ "$normalized_current" = "$alb_dns_name" ]; then
  log_info "Route53 Aliasは現在のALBを指しています（更新不要）"
else
  log_warn "Route53 Aliasが現在のALBと異なります。ALBが再作成された可能性があります。"
  echo ""
  echo "  現在のAlias  : $current_alias_dns"
  echo "  新しいALB    : dualstack.${alb_dns_name}"
  echo ""
  echo "  ${COLOR_YELLOW}以下のコマンドで手動更新してください（このスクリプトは自動実行しません）:${COLOR_RESET}"
  cat <<EOF

  aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${ROUTE53_RECORD_NAME}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${alb_zone_id}",
          "DNSName": "dualstack.${alb_dns_name}",
          "EvaluateTargetHealth": true
        }
      }
    }]
  }'

EOF
  echo "  ${COLOR_YELLOW}更新後、このスクリプトを再実行するか、以降の手順（Vercel resume等）を手動で続けてください。${COLOR_RESET}"
  die "Route53 Aliasの手動更新が必要です" "上記コマンドを実行してから ./scripts/prod/recover.sh を再実行してください。"
fi

# --------------------------------------------------
# 16. API health確認（カスタムドメイン経由）
# --------------------------------------------------
log_step "API health確認（カスタムドメイン経由）"
api_code=$(curl -s -o /dev/null -w "%{http_code}" "https://${ROUTE53_RECORD_NAME}${API_HEALTH_PATH}" || echo "000")
echo "  https://${ROUTE53_RECORD_NAME}${API_HEALTH_PATH} -> HTTP $api_code"
if [ "$api_code" != "200" ]; then
  log_warn "API health確認がHTTP 200以外です"
  health_ok=false
fi

# --------------------------------------------------
# 17. Vercel resume
# ・12〜16のAWS側ヘルスチェックがすべて正常な場合のみ実行する。
#   API/ALB等の必須チェックが失敗している状態で一般公開（resume）
#   してしまうと、動いていないバックエンドにユーザーを誘導する
#   ことになるため、health_okがfalseの場合はresumeせず停止する
# --------------------------------------------------
log_step "Vercel Project resume判定"
if [ "$health_ok" = true ]; then
  log_info "AWS側のヘルスチェックがすべて正常なため、Vercel Projectをresumeします"
  if vercel project resume "$VERCEL_PROJECT_NAME" --yes 2>&1; then
    log_info "Vercel Projectをresumeしました"
  else
    log_warn "Vercel Projectのresumeに失敗しました。手動で 'vercel project resume $VERCEL_PROJECT_NAME' を実行してください。"
  fi
else
  log_warn "AWS側のヘルスチェックに失敗があるため、Vercel Projectのresumeをスキップしました"
  echo ""
  echo "  ${COLOR_YELLOW}上記の警告（ECS/ALB/API）を解消してから、手動で以下を実行してください:${COLOR_RESET}"
  echo "    vercel project resume $VERCEL_PROJECT_NAME"
fi

# --------------------------------------------------
# 18. Frontend health確認
# --------------------------------------------------
log_step "Frontend health確認"
frontend_code=$(curl -s -o /dev/null -w "%{http_code}" "https://${FRONTEND_DOMAIN}" || echo "000")
echo "  https://${FRONTEND_DOMAIN} -> HTTP $frontend_code"

# --------------------------------------------------
# 19. 最終terraform plan（No changes期待）
# --------------------------------------------------
log_step "最終terraform plan確認"
( cd "$TF_AWS_DIR" && terraform plan -no-color -input=false -detailed-exitcode ) && \
  log_info "No changes（想定通り）" || {
    code=$?
    if [ "$code" = "2" ]; then
      log_warn "terraform planに差分が残っています。内容を確認してください。"
    else
      log_warn "terraform planの実行でエラーが発生しました。"
    fi
  }

log_step "復旧フロー完了"
if [ "$health_ok" != true ]; then
  log_warn "AWS側のヘルスチェックに未解消の失敗があります。Vercel resumeも未実行です。"
fi
echo "  ./scripts/prod/status.sh で最終状態を再確認してください。"
