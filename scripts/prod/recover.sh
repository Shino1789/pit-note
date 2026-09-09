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
#    2. Terraform backend確認 / 3. terraform init
#       （AWS用に加えてVercel用 infra/terraform/vercel も同時に初期化する。
#       resume_vercel_project がVercel Terraformのremote stateから
#       project_idを取得するため、17.の直前ではなくここで先に
#       初期化しておく）
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
#   15. Route53 Alias確認・自動UPSERT（ALB再作成でDNS名が変わった
#       場合、api.pitviaapp.comのA Aliasだけを新ALBへ自動更新する。
#       Route53 Hosted Zone自体はTerraform管理外のまま）
#   16. API health確認（カスタムドメイン経由）
#   17. Vercel resume ※12〜16すべてが正常な場合のみ実行する
#       （AWS側の復旧を確認しないまま一般公開しないための安全条件）
#   18. Frontend health確認
#   19. 最終terraform plan（No changes期待）
#
# 使い方:
#   ./scripts/prod/recover.sh                    # 通常実行
#   ./scripts/prod/recover.sh --force-jwt-reset  # 既存JWT値があっても再生成する
#
# 終了コード:
#   0 = AWS側ヘルスチェック・Vercel resume・terraform planすべて正常（完全復旧）
#   1 = 途中でdie（致命的エラー）、または最後まで到達したが一部が
#       未解消（health_ok=false / Vercel resume失敗 / terraform plan
#       自体の失敗のいずれか）。画面表示が「復旧フロー完了」でも
#       exit 1になりうるため、必ず終了コードで判定すること
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

require_commands aws terraform jq curl vercel gh git openssl dig

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

# ・Vercel用（infra/terraform/vercel）もここで初期化する。17.の
#   Vercel resumeで使う resume_vercel_project は
#   `terraform -chdir=infra/terraform/vercel output -raw project_id`
#   に依存しており、このディレクトリが未初期化の環境（新しい
#   CIランナー等）で実行するとproject_id取得に失敗し、AWS側の
#   復旧が完了しているのにVercel resumeだけ失敗する事態が実地で
#   発生した。特定マシンのローカル状態に依存させないよう、S3
#   backend（remote state）から確実に読める状態にしておく
check_terraform_backend "$TF_VERCEL_DIR" "s3"
( cd "$TF_VERCEL_DIR" && terraform init -input=false )

# --------------------------------------------------
# 4. terraform plan
# --------------------------------------------------
log_step "terraform plan"
APPLY_PLAN_FILE="$TF_AWS_DIR/.prod-recover.apply.tfplan"
# ・terraform applyが失敗すると、set -eによりこの後の明示的な
#   `rm -f`（成功時・キャンセル時のcleanup）に到達できないまま
#   スクリプトが終了し、plan fileが残ってしまっていた。EXIT trapで
#   スクリプトの終了経路（成功／die／set -eによる異常終了）に
#   関わらず確実に削除する。既存のcleanup（yes/no・EOF時の明示的な
#   rm -f）はそのまま維持し、この trap はそれらを置き換えるのでは
#   なく「apply失敗時にも確実に片付ける」ための追加の安全網。
#   失敗したplanを再利用して再applyする、といった動作は行わない
#   （このtrapは削除のみを行う）
cleanup_apply_plan_file() {
  rm -f "$APPLY_PLAN_FILE"
}
trap cleanup_apply_plan_file EXIT
( cd "$TF_AWS_DIR" && terraform plan -no-color -input=false -out="$APPLY_PLAN_FILE" )
# ・-no-colorを付けないと、terraform showの出力にANSI色コードが
#   混ざりgrepの行頭マッチ（^Plan:等）が一致しなくなるため必須
plan_summary=$( (cd "$TF_AWS_DIR" && terraform show -no-color "$APPLY_PLAN_FILE") | grep -E "^Plan:|^No changes" || echo "Plan: (取得失敗)")
echo ""
echo "  $plan_summary"

# --------------------------------------------------
# 5. destroy/replaceが含まれていないことを確認
# ・plan summaryの取得自体に失敗した場合（terraform showの異常終了、
#   出力形式が想定外でgrepが空を返す等）は、destroy/replaceの
#   有無を判定できていない＝最も危険な状態のため、fail-closedで
#   即座に停止する（fail-openで確認プロンプトへ進めない）
# --------------------------------------------------
if [[ "$plan_summary" == *"(取得失敗)"* ]]; then
  die "plan summaryを取得できず、destroy/replaceが含まれていないか確認できませんでした" \
    "terraform planを再実行して内容を確認してください。"
fi
if [[ "$plan_summary" == *"to destroy"* ]] && [[ "$plan_summary" != *"0 to destroy"* ]]; then
  die "planにdestroy/replaceが含まれています。想定外の変更です。" \
    "terraform planを再実行して内容を確認してください。"
fi

# --------------------------------------------------
# 6. ユーザー確認 → 7. terraform apply
# --------------------------------------------------
log_step "terraform apply確認"
# ・set -e下でread自体がEOF等で失敗すると、この行で即座に
#   スクリプトが終了し、以降の「キャンセルしました」の表示も
#   plan file削除も行われないまま終了する。read自体をif条件に
#   置くことでその挙動を吸収し、yes / no / EOF・read失敗の
#   3パターンを明示的に分岐する（shutdown.shと同じパターン）
if read -r -p "上記planでAWSリソースを作成/更新します。続行しますか？ [yes/no]: " answer; then
  if [ "$answer" != "yes" ]; then
    log_info "キャンセルしました"
    rm -f "$APPLY_PLAN_FILE"
    exit 0
  fi
else
  log_info "入力を受け取れなかったためキャンセルしました"
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

# ・workflow_dispatch APIはトリガーしたrunのIDを同期的に返さない
#   仕様のため、直後に一覧から特定する。deploy.ymlはpushトリガーも
#   持つため、他の人の変更が同時にpushされた場合など「直近1件」
#   （--limit 1）だけを見ると別のrunを取り違える恐れがある。
#   トリガー時刻以降・event=workflow_dispatch・headBranch=mainの
#   runに絞ることで取り違えのリスクを大きく減らす（複数人が同時に
#   workflow_dispatchした場合の完全な一意特定までは保証しない）
# ・`gh run list --jq`はjq式を1つだけ受け取るオプションであり、
#   `gh`自身にjqの`--arg`を渡すことはできない（`--jq --arg since ...`
#   は`gh`に未知のサブコマンド`since`として解釈されエラーになる）。
#   そのため `gh run list --json ...` でJSONを取得し、パイプで
#   通常のjqへ`--arg`を渡す2段階の方式にする
trigger_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
run_output=$(gh workflow run deploy.yml --ref main 2>&1) || die "workflow_dispatchの実行に失敗しました: $run_output" \
  "GitHub CLIの認証状態（gh auth status）を確認してください。"
echo "$run_output"

log_info "CDの起動を検知しています..."
run_id=""
for _ in $(seq 1 10); do
  sleep 3
  run_id=$(gh run list \
    --workflow=deploy.yml \
    --limit 10 \
    --json databaseId,event,createdAt,headBranch \
    2>/dev/null |
    jq -r --arg since "$trigger_time" '
      [.[] |
        select(
          .event == "workflow_dispatch" and
          .headBranch == "main" and
          .createdAt >= $since
        )
      ]
      | sort_by(.createdAt)
      | last
      | .databaseId // empty
    ' 2>/dev/null || echo "")
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

# ・CD側で既にecs wait services-stableを経ているため通常は初回で
#   安定しているはずだが、単発チェックだと一時的な揺らぎを誤って
#   失敗と判定しうるため、短いbounded retryで確認する
ecs_ok=false
for attempt in $(seq 1 "$RECOVER_HEALTH_MAX_ATTEMPTS"); do
  ecs_json=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
    --query 'services[0].{status:status,runningCount:runningCount,desiredCount:desiredCount,taskDefinition:taskDefinition,rolloutState:deployments[0].rolloutState}' \
    --output json)
  ecs_running=$(echo "$ecs_json" | jq -r '.runningCount')
  ecs_desired=$(echo "$ecs_json" | jq -r '.desiredCount')

  if [ "$ecs_running" = "$ecs_desired" ] && [ "$ecs_running" != "0" ]; then
    ecs_ok=true
    break
  fi
  [ "$attempt" -lt "$RECOVER_HEALTH_MAX_ATTEMPTS" ] && sleep "$RECOVER_HEALTH_INTERVAL_SECONDS"
done

echo "$ecs_json" | jq -r '
  "  status         : \(.status)",
  "  runningCount   : \(.runningCount)",
  "  desiredCount   : \(.desiredCount)",
  "  taskDefinition : \(.taskDefinition)",
  "  rolloutState   : \(.rolloutState)"
'
if [ "$ecs_ok" != true ]; then
  log_warn "ECSのrunningCountがdesiredCountと一致していません（${RECOVER_HEALTH_MAX_ATTEMPTS}回確認）"
  health_ok=false
fi

# --------------------------------------------------
# 13. ALB Target Health確認
# --------------------------------------------------
log_step "ALB Target Health確認"
tg_arn=$(aws elbv2 describe-target-groups --names "$TARGET_GROUP_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

tg_ok=false
for attempt in $(seq 1 "$RECOVER_HEALTH_MAX_ATTEMPTS"); do
  tg_states=$(aws elbv2 describe-target-health --target-group-arn "$tg_arn" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)
  if echo "$tg_states" | grep -qw "healthy"; then
    tg_ok=true
    break
  fi
  [ "$attempt" -lt "$RECOVER_HEALTH_MAX_ATTEMPTS" ] && sleep "$RECOVER_HEALTH_INTERVAL_SECONDS"
done

echo "  $tg_states"
if [ "$tg_ok" != true ]; then
  log_warn "ALB Target Groupにhealthyなターゲットがありません（${RECOVER_HEALTH_MAX_ATTEMPTS}回確認）"
  health_ok=false
fi

# --------------------------------------------------
# 14. ALB直接health確認（DNSを経由しない）
# --------------------------------------------------
log_step "ALB直接health確認"
alb_dns_name=$( (cd "$TF_AWS_DIR" && terraform output -raw alb_dns_name) )
alb_zone_id=$( (cd "$TF_AWS_DIR" && terraform output -raw alb_zone_id) )
# ・alb_dns_name自体もDNS解決を要するため、実行環境のローカルDNSが
#   一時的に不調な場合に備えてhttp_code_with_dns_fallback()を使う
#   （DNS解決失敗＝curl exit 6の場合のみCloudflare DNSでフォールバック。
#   IPアドレスはハードコードせず毎回digで取得する）
alb_direct_code=$(http_code_with_dns_fallback \
  "https://${alb_dns_name}${API_HEALTH_PATH}" "$alb_dns_name" 443 \
  -k -H "Host: ${ROUTE53_RECORD_NAME}")
echo "  https://${alb_dns_name}${API_HEALTH_PATH} (Host: ${ROUTE53_RECORD_NAME}) -> HTTP $alb_direct_code"

if [ "$alb_direct_code" != "200" ]; then
  log_warn "ALB経由の直接ヘルスチェックが200以外です。ECS/ALBの状態を確認してください。"
  health_ok=false
fi

# --------------------------------------------------
# 15. Route53 Alias確認・自動UPSERT
# ・Route53 Hosted Zone自体はTerraform管理外のまま変更しない。
#   api.pitviaapp.com のA Alias 1レコードだけを、recover.shが
#   現在のALB情報（DNS名・Hosted Zone ID）へ自動UPSERTする。
#   ALBがdestroy→recreateされてDNS名が変わっても、このステップで
#   自動的に新ALBへ向け直されるため、手動対応が不要になる
# ・DNSNameにdualstack.プレフィックスを付けない: 実機のALB
#   （aws_lb.main）はip_address_type=ipv4（dualstack非対応）で
#   作成されており、実際に機能しているRoute53レコードも
#   dualstackプレフィックス無しのプレーンなALB DNS名を使っている
#   ことを`aws elbv2 describe-load-balancers`/
#   `aws route53 list-resource-record-sets`で確認済み。推測ではなく
#   実環境の設定に合わせている
# --------------------------------------------------
log_step "Route53 Alias確認・自動UPSERT"

# ・UPSERT実行条件1〜3: terraform apply成功（既にここまで到達している
#   時点で満たしている）・alb_dns_name/alb_zone_idが取得できていること
if [ -z "$alb_dns_name" ]; then
  die "ALB DNS名を取得できませんでした（terraform output alb_dns_name）" \
    "terraform state show aws_lb.main で状態を確認してください。"
fi
if [ -z "$alb_zone_id" ]; then
  die "ALB Hosted Zone IDを取得できませんでした（terraform output alb_zone_id）" \
    "terraform state show aws_lb.main で状態を確認してください。"
fi

hosted_zone_id=$(aws route53 list-hosted-zones-by-name --dns-name "$FRONTEND_DOMAIN" \
  --query "HostedZones[?Name=='${FRONTEND_DOMAIN}.'].Id | [0]" --output text 2>/dev/null | sed 's|/hostedzone/||')

# ・UPSERT実行条件4: Route53 Hosted Zone IDが取得できていること
#   （見つからない場合はRoute53側の重大な問題の可能性があるため、
#   自動UPSERTはせず即座に停止する）
if [ -z "$hosted_zone_id" ] || [ "$hosted_zone_id" = "None" ]; then
  die "Route53 Hosted Zone（$FRONTEND_DOMAIN）が見つかりませんでした" \
    "Route53のHosted Zoneが存在するか、AWS権限が正しいか確認してください。"
fi

echo "  Route53 Hosted Zone ID : $hosted_zone_id"
echo "  Route53 Record Name    : $ROUTE53_RECORD_NAME"
echo "  新しいALB DNS          : $alb_dns_name"
echo "  ALB Zone ID            : $alb_zone_id"

current_alias_dns=$(aws route53 list-resource-record-sets --hosted-zone-id "$hosted_zone_id" \
  --query "ResourceRecordSets[?Name=='${ROUTE53_RECORD_NAME}.'].AliasTarget.DNSName | [0]" --output text 2>/dev/null)
echo "  現在のAlias             : ${current_alias_dns:-(レコードなし)}"

normalized_current=$(echo "$current_alias_dns" | sed 's/^dualstack\.//; s/\.$//')

# ・UPSERT実行条件5: レコードが既に存在する（かつ現在のALBと不一致）、
#   または存在しない（UPSERTで新規作成可能）場合、自動UPSERTする。
#   既に現在のALBを指している場合のみUPSERTをスキップする
if [ -n "$current_alias_dns" ] && [ "$current_alias_dns" != "None" ] && [ "$normalized_current" = "$alb_dns_name" ]; then
  log_info "Route53 Aliasは現在のALBを指しています（更新不要）"
else
  if [ -z "$current_alias_dns" ] || [ "$current_alias_dns" = "None" ]; then
    log_info "Route53レコード（$ROUTE53_RECORD_NAME）が存在しないため、新規作成します"
  else
    log_info "Route53 Aliasが現在のALBと異なるため、自動UPSERTします（ALBが再作成された可能性があります）"
  fi

  # ・change-batch JSONはjq -nで生成する（シェルインジェクション・
  #   クォート崩れを避けるため、文字列結合ではなく--argで渡す）
  change_batch=$(jq -n \
    --arg name "$ROUTE53_RECORD_NAME" \
    --arg alb_zone_id "$alb_zone_id" \
    --arg alb_dns "$alb_dns_name" \
    '{
      Changes: [{
        Action: "UPSERT",
        ResourceRecordSet: {
          Name: $name,
          Type: "A",
          AliasTarget: {
            HostedZoneId: $alb_zone_id,
            DNSName: $alb_dns,
            EvaluateTargetHealth: true
          }
        }
      }]
    }')

  log_info "Route53 UPSERT実行開始"
  if ! upsert_error=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "$hosted_zone_id" --change-batch "$change_batch" 2>&1); then
    die "Route53 Aliasの自動UPSERTに失敗しました: $upsert_error" \
      "AWS権限（route53:ChangeResourceRecordSets）や change-batch の内容を確認してください。"
  fi
  log_info "Route53 UPSERT成功"

  # ・DNS伝播の完了を待つ必要はなく、Route53 API上のレコードが
  #   正しく更新されたことだけを確認する
  updated_alias_dns=$(aws route53 list-resource-record-sets --hosted-zone-id "$hosted_zone_id" \
    --query "ResourceRecordSets[?Name=='${ROUTE53_RECORD_NAME}.'].AliasTarget.DNSName | [0]" --output text 2>/dev/null)
  normalized_updated=$(echo "$updated_alias_dns" | sed 's/^dualstack\.//; s/\.$//')

  if [ "$normalized_updated" != "$alb_dns_name" ]; then
    die "Route53レコードの更新後再確認に失敗しました（$ROUTE53_RECORD_NAME が新ALBを指していません）" \
      "aws route53 list-resource-record-sets --hosted-zone-id $hosted_zone_id で内容を確認してください。"
  fi
  log_info "Route53 Aliasを新しいALBへ更新しました（$ROUTE53_RECORD_NAME -> $alb_dns_name）"
fi

# --------------------------------------------------
# 16. API health確認（カスタムドメイン経由）
# ・Route53 API上のUPSERTが成功していても、公開DNS解決側への反映
#   には多少の時間差がありうるため、bounded retryで確認する
#   （Route53 API上でAliasが新ALBを指していることは15.で既に
#   確認済みだが、それだけではhealth_ok=trueにしない。実際に
#   カスタムドメイン経由でHTTP 200が返ることまで確認する）
# --------------------------------------------------
log_step "API health確認（カスタムドメイン経由）"
api_code="000"
api_ok=false
for attempt in $(seq 1 "$RECOVER_HEALTH_MAX_ATTEMPTS"); do
  # ・DNS解決失敗（curl exit 6）の場合のみCloudflare DNSでフォールバック
  #   する（http_code_with_dns_fallback()、common.sh参照）。実行環境の
  #   ローカルDNSが一時的に不調でも、実際のAPIが正常なら誤って
  #   health_ok=falseにしないため
  api_code=$(http_code_with_dns_fallback \
    "https://${ROUTE53_RECORD_NAME}${API_HEALTH_PATH}" "$ROUTE53_RECORD_NAME" 443)
  if [ "$api_code" = "200" ]; then
    api_ok=true
    break
  fi
  [ "$attempt" -lt "$RECOVER_HEALTH_MAX_ATTEMPTS" ] && sleep "$RECOVER_HEALTH_INTERVAL_SECONDS"
done

echo "  https://${ROUTE53_RECORD_NAME}${API_HEALTH_PATH} -> HTTP $api_code"
if [ "$api_ok" != true ]; then
  log_warn "API health確認がHTTP 200以外です（${RECOVER_HEALTH_MAX_ATTEMPTS}回確認）"
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
vercel_resume_ok=false
if [ "$health_ok" = true ]; then
  log_info "AWS側のヘルスチェックがすべて正常なため、Vercel Projectをresumeします"
  if resume_vercel_project; then
    log_info "Vercel Projectをresumeしました"
    vercel_resume_ok=true
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
frontend_code=$(http_code_with_dns_fallback "https://${FRONTEND_DOMAIN}" "$FRONTEND_DOMAIN" 443)
echo "  https://${FRONTEND_DOMAIN} -> HTTP $frontend_code"

# --------------------------------------------------
# 19. 最終terraform plan（No changes期待）
# ・-detailed-exitcodeの意味論（Terraform公式）に沿って明確に分岐する:
#   0=No changes（正常） / 2=差分あり（警告。db_name等、意図的に
#   未applyの差分が残ることがあるため許容） / それ以外=Terraform
#   コマンド自体の失敗（認証切れ・state破損等の重大なエラー）
# --------------------------------------------------
log_step "最終terraform plan確認"
if ( cd "$TF_AWS_DIR" && terraform plan -no-color -input=false -detailed-exitcode ); then
  plan_exit=0
else
  plan_exit=$?
fi

case "$plan_exit" in
  0) log_info "No changes（想定通り）" ;;
  2) log_warn "terraform planに差分が残っています。内容を確認してください。" ;;
  *) log_error "terraform planの実行に失敗しました（exit $plan_exit）" ;;
esac

# --------------------------------------------------
# 復旧フロー完了判定
# ・AWS側ヘルスチェック（health_ok）・Vercel resume成否
#   （vercel_resume_ok）・最終terraform plan（plan_exitが0か2）の
#   すべてが揃って初めて「完全復旧」とし、exit 0にする。
#   1つでも欠けていれば「部分復旧」としてexit 1で終了する
#   （画面上は「復旧完了」と見えても実際には未完了、という
#   状態を終了コードからも判別できるようにするため）
# --------------------------------------------------
log_step "復旧フロー完了"
overall_ok=true
[ "$health_ok" = true ] || overall_ok=false
[ "$vercel_resume_ok" = true ] || overall_ok=false
{ [ "$plan_exit" = "0" ] || [ "$plan_exit" = "2" ]; } || overall_ok=false

echo "  ./scripts/prod/status.sh で最終状態を再確認してください。"

if [ "$overall_ok" = true ]; then
  log_info "AWS側ヘルスチェック・Vercel resume・terraform planすべて正常です。復旧が完全に完了しました"
  exit 0
else
  log_warn "復旧が部分的に未完了です。上記の警告・エラーを解消してください"
  exit 1
fi
