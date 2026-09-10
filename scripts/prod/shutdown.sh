#!/bin/bash

# ==================================================
# 本番β環境 停止/破棄スクリプト
#
# AWS（RDS/S3/ECR/ECS/ALB/NAT Gateway等のTerraform管理リソース）を
# destroyする。Vercel Projectの一時非公開化（pause）は事前に
# ユーザーが対話ターミナルで実行しておく前提とし、本スクリプトは
# pause済みであることの確認のみ行う（理由は下記参照）。
#
# 重要:
# ・RDSのデータ、S3の画像、ECRのDocker image、JWT secretは失われる
# ・Route53 Hosted Zone / IAM / OIDC / ACM / AWS Budgets / Vercel Project
#   自体は削除されない（Terraform管理外のため）
# ・`vercel project pause`は非対話環境から実行できない仕様であることが
#   実機確認済み（--non-interactiveを付けても、stdinへ確認文字列を
#   pipeしても、TTY判定の時点で内容を見ずに拒否される。Vercel側が
#   意図的に自動化を禁止している）。そのため本スクリプトはpauseを
#   実行せず、事前にpause済みであることを確認するfail-closed設計に
#   している: pauseされていない/確認できない場合、AWS destroyは
#   一切実行せず終了する（Frontendが公開されたままBackendだけ
#   destroyされる中途半端な状態を避けるため）
# ・実行には二段階の明示的確認が必須
#   1) スクリプト開始直後: 破棄する意思そのものを、固定フレーズの
#      完全一致入力で確認する（誤って実行しただけでは進まない）
#   2) terraform plan -destroy 実行後: 実際のdestroy対象を提示した
#      うえで、続行の意思を再確認する
#   どちらか一方でも拒否されたら、破壊的操作は一切行わず終了する
# ・ユーザー確認後のdestroy自体は、一時的なAWS API/DNSエラー等に
#   対してbounded retry（最大DESTROY_MAX_ATTEMPTS回・累計
#   DESTROY_MAX_ELAPSED_SECONDS秒まで。lib/common.sh参照）を行う。
#   retryのたびに古いplanは破棄し、現在のAWS状態から新しい
#   terraform plan -destroyを作り直してから適用する。設定ミスや
#   権限エラー等の恒久的な問題は即座に停止する（fail-closed）
#
# 使い方:
#   ./scripts/prod/shutdown.sh            # 通常実行（二段階確認あり）
#   ./scripts/prod/shutdown.sh --dry-run  # destroy対象の確認のみ（確認・destroyともにしない）
#
# 終了コード:
#   0 = destroy成功、かつ完了検証（Terraform管理対象0件・保護対象
#       リソース健在・消去対象リソースの削除確認）すべて正常
#   1 = destroy自体の失敗（die）、またはdestroyは成功したが完了検証で
#       未解消の項目がある場合（画面表示が「destroyが完了しました」
#       でもexit 1になりうるため、必ず終了コードで判定すること）
# ==================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) die "不明な引数です: $arg" "使い方: ./scripts/prod/shutdown.sh [--dry-run]" ;;
  esac
done

require_commands aws terraform jq curl vercel git

# --------------------------------------------------
# 0. 破棄する意思そのものの確認（1段階目）
# ・terraform plan -destroy より前に行う
#   （AWSへ一切問い合わせる前に、意思がなければ即終了させるため）
# ・--dry-runの場合はここをスキップする（確認・destroyともに行わない
#   プレビュー専用モードのため、破棄意思の確認自体が不要）
# --------------------------------------------------
if [ "$DRY_RUN" = false ]; then
  log_step "本番環境破棄の意思確認（1/2）"
  echo ""
  echo "${COLOR_RED}${COLOR_BOLD}========================================${COLOR_RESET}"
  echo "${COLOR_RED}${COLOR_BOLD}WARNING${COLOR_RESET}"
  echo "${COLOR_RED}${COLOR_BOLD}Pitvia β 本番環境を破棄しようとしています。${COLOR_RESET}"
  echo "${COLOR_RED}${COLOR_BOLD}========================================${COLOR_RESET}"
  echo ""
  echo "RDSデータ、S3画像、ECRイメージ、JWT Secret等が失われます。"
  echo ""
  echo "続行する場合は以下を入力してください:"
  echo ""
  echo "  DESTROY PITVIA BETA"
  echo ""
  confirm_exact_phrase "DESTROY PITVIA BETA"
  log_info "意思確認を通過しました。実際の破棄対象の確認へ進みます。"
fi

# --------------------------------------------------
# 1. AWSアカウント/リージョン確認
# --------------------------------------------------
check_aws_identity

# --------------------------------------------------
# 2. Terraform directory確認
# --------------------------------------------------
log_step "Terraform directory確認"
echo "  対象: $TF_AWS_DIR"
check_terraform_backend "$TF_AWS_DIR" "s3"
log_info "S3 backend構成を確認しました"

# --------------------------------------------------
# 3. Vercel project確認
# --------------------------------------------------
check_vercel_auth

# --------------------------------------------------
# 4. 現在のgit branch確認
# --------------------------------------------------
show_git_context

# --------------------------------------------------
# 5. Terraform backend確認（init）
# --------------------------------------------------
log_step "terraform init"
( cd "$TF_AWS_DIR" && terraform init -input=false )

# --------------------------------------------------
# 6. terraform plan -destroy 実行
# --------------------------------------------------
log_step "terraform plan -destroy"
DESTROY_PLAN_FILE="$TF_AWS_DIR/.prod-shutdown.destroy.tfplan"
( cd "$TF_AWS_DIR" && terraform plan -destroy -no-color -input=false -out="$DESTROY_PLAN_FILE" )

# --------------------------------------------------
# 7. destroy対象を表示
# ・-no-colorを付けないと、terraform showの出力にANSI色コードが
#   混ざりgrepの行頭マッチ（^  # 等）が一致しなくなるため必須
# ・validate_destroy_only_plan（lib/common.sh）で、destroy以外の
#   変更（add/change/replace）や、想定していないリソース種別が
#   含まれていないことを確認する。「常に38件」という固定数ではなく、
#   「想定される管理対象の型のdestroyだけが残っている」ことを見る
# --------------------------------------------------
log_step "destroy対象一覧"
( cd "$TF_AWS_DIR" && terraform show -no-color "$DESTROY_PLAN_FILE" | grep -E "^  # " || true )
echo ""
if ! validate_destroy_only_plan "$DESTROY_PLAN_FILE"; then
  rm -f "$DESTROY_PLAN_FILE"
  die "想定外のplan結果です（destroy以外の変更、またはreplace、または想定外のリソース種別が含まれています）" \
    "terraform show \"$DESTROY_PLAN_FILE\" の内容を手動で確認してください（このファイルは削除済みのため、再度 terraform plan -destroy で確認してください）。"
fi
plan_summary=$( (cd "$TF_AWS_DIR" && terraform show -no-color "$DESTROY_PLAN_FILE") | grep -E "^Plan:" || echo "Plan: (取得失敗)")

if [ "$DRY_RUN" = true ]; then
  log_info "--dry-run のため、ここで終了します（destroyは実行していません）"
  rm -f "$DESTROY_PLAN_FILE"
  exit 0
fi

# --------------------------------------------------
# 8. 実際のdestroy対象の最終確認（2段階目）
# --------------------------------------------------
log_step "最終確認（2/2）"
echo ""
echo "${COLOR_RED}${COLOR_BOLD}PITVIA BETAのAWSリソースを破棄します。${COLOR_RESET}"
echo "${COLOR_RED}βデータ（RDS）、S3画像、ECR image、JWT secret等が失われます。${COLOR_RESET}"
echo ""
echo "  $plan_summary"
echo ""
# ・readをbareで呼ぶと、EOF/read失敗時（exit status != 0）に
#   ifの判定へ届く前にset -eで即終了してしまい、"キャンセルしました"
#   の表示もplan file削除も行われないまま終了する。
#   read自体をif条件に置くことでその挙動を吸収し、
#   yes / no / EOF・read失敗の3パターンを明示的に分岐する
if read -r -p "本当に続行しますか？ [yes/no]: " answer; then
  if [ "$answer" != "yes" ]; then
    log_info "キャンセルしました（destroyは実行していません）"
    rm -f "$DESTROY_PLAN_FILE"
    exit 0
  fi
else
  log_info "入力を受け取れなかったためキャンセルしました（destroyは実行していません）"
  rm -f "$DESTROY_PLAN_FILE"
  exit 0
fi

# --------------------------------------------------
# 9. Vercel pause状態確認
# ・`vercel project pause`はVercel側の仕様により非対話環境から
#   実行できないため（スクリプト冒頭のコメント参照）、pauseの実行は
#   ユーザーが対話ターミナルで事前に行っておく前提とする。
#   ここではpause済みであることを確認するのみ。
# ・fail-closed: pause済みと確認できない場合、AWS destroyは絶対に
#   実行しない。Frontend（Vercel）が公開されたままBackend（AWS）だけ
#   destroyされる、という中途半端な状態を避けるため
# --------------------------------------------------
log_step "Vercel Project のpause状態確認"
vercel_paused_state=$(get_vercel_paused_state)
case "$vercel_paused_state" in
  true)
    log_info "Vercel Projectはpause済みです"
    ;;
  false)
    rm -f "$DESTROY_PLAN_FILE"
    die "Vercel Projectがpauseされていないため、AWS destroyを中止します" \
      "対話ターミナルで 'vercel project pause $VERCEL_PROJECT_NAME' を実行し（プロジェクト名の入力確認が必要です）、pause完了後に ./scripts/prod/shutdown.sh を再実行してください。"
    ;;
  *)
    rm -f "$DESTROY_PLAN_FILE"
    die "Vercel Projectのpause状態を確認できませんでした" \
      "VERCEL_API_TOKEN環境変数を設定するか、'vercel project inspect $VERCEL_PROJECT_NAME' で手動確認してから ./scripts/prod/shutdown.sh を再実行してください。"
    ;;
esac

# --------------------------------------------------
# 10. AWS Terraform destroy（bounded retry対応）
# ・初回（attempt 1）は、8.でユーザーが確認・承認した
#   $DESTROY_PLAN_FILE をそのまま適用する（承認後に無関係な
#   再計算を挟まないため）
# ・2回目以降（attempt 2+）は、古いplanを絶対に使い回さない。
#   NAT Gateway/ALB destroy完了後の一時的なEventually Consistent、
#   DNS/AWS API一時障害等でapplyが失敗した場合、現在のAWS状態を
#   refreshした新しいplan -destroyを作り直してから再度applyする
#   （AWS上で既に削除済みのリソースは、この再refreshで自動的に
#   Terraform Stateとの不整合が解消される。terraform state rmは
#   一切使用しない）
# ・retryは無限に行わない。最大試行回数（DESTROY_MAX_ATTEMPTS）と
#   累計経過時間（DESTROY_MAX_ELAPSED_SECONDS）の両方で上限を設け、
#   一時的なエラー（classify_destroy_error=retry）の場合のみ
#   backoffを挟んで再試行する。それ以外のエラーは即座に停止する
# --------------------------------------------------
log_step "terraform apply（destroy, 最大${DESTROY_MAX_ATTEMPTS}回試行）"

destroy_start_time=$(date +%s)
destroy_success=false
current_plan_file="$DESTROY_PLAN_FILE"

for attempt in $(seq 1 "$DESTROY_MAX_ATTEMPTS"); do
  if [ "$attempt" -gt 1 ]; then
    elapsed=$(( $(date +%s) - destroy_start_time ))
    if [ "$elapsed" -ge "$DESTROY_MAX_ELAPSED_SECONDS" ]; then
      log_warn "累計経過時間が上限（${DESTROY_MAX_ELAPSED_SECONDS}秒）に達したため、これ以上retryしません"
      break
    fi

    backoff=$(( attempt * DESTROY_BACKOFF_BASE_SECONDS ))
    [ "$backoff" -gt "$DESTROY_BACKOFF_MAX_SECONDS" ] && backoff=$DESTROY_BACKOFF_MAX_SECONDS
    log_info "attempt ${attempt}/${DESTROY_MAX_ATTEMPTS}: ${backoff}秒待機してから、現在のAWS状態で新しいplanを作り直します"
    sleep "$backoff"

    # 古いplanは絶対に使い回さない
    rm -f "$current_plan_file"
    current_plan_file="$TF_AWS_DIR/.prod-shutdown.destroy.attempt${attempt}.tfplan"
    log_step "terraform plan -destroy（attempt ${attempt}/${DESTROY_MAX_ATTEMPTS}、状態を再取得）"
    ( cd "$TF_AWS_DIR" && terraform plan -destroy -no-color -input=false -out="$current_plan_file" )

    if ! validate_destroy_only_plan "$current_plan_file"; then
      rm -f "$current_plan_file"
      die "attempt ${attempt}: 新しいplanに想定外の内容が含まれていたため停止します" \
        "cd infra/terraform/aws && terraform plan -destroy の内容を手動で確認してください。"
    fi
  fi

  log_step "terraform apply（destroy, attempt ${attempt}/${DESTROY_MAX_ATTEMPTS}）"
  apply_log=$(mktemp "${TMPDIR:-/tmp}/pitvia-destroy-apply.XXXXXX")
  if ( cd "$TF_AWS_DIR" && terraform apply -no-color -input=false "$current_plan_file" ) 2>&1 | tee "$apply_log"; then
    destroy_success=true
    rm -f "$current_plan_file" "$apply_log"
    break
  fi

  apply_error=$(cat "$apply_log")
  rm -f "$apply_log"
  classification=$(classify_destroy_error "$apply_error")

  if [ "$classification" != "retry" ]; then
    rm -f "$current_plan_file"
    die "attempt ${attempt}/${DESTROY_MAX_ATTEMPTS}: destroyが失敗しました（即停止対象のエラーと判定）" \
      "上記のエラー内容を確認してください。設定ミス・権限不足・想定外の変更の可能性があります。原因を解消してから ./scripts/prod/shutdown.sh を再実行してください（一部リソースが既に削除されている場合があります。./scripts/prod/status.sh で現状を確認してください）。"
  fi

  if [ "$attempt" -eq "$DESTROY_MAX_ATTEMPTS" ]; then
    rm -f "$current_plan_file"
    die "attempt ${attempt}/${DESTROY_MAX_ATTEMPTS}: retry上限に達しました（一時的なエラーが解消しませんでした）" \
      "./scripts/prod/status.sh で現状を確認したうえで、./scripts/prod/shutdown.sh を再実行してください（新しいplanが自動的に作り直されます）。"
  fi

  log_warn "attempt ${attempt}/${DESTROY_MAX_ATTEMPTS}: 一時的なエラーと判定したため、retryします"
done

if [ "$destroy_success" != true ]; then
  die "destroyが完了しませんでした" "./scripts/prod/status.sh で現状を確認してください。"
fi

# --------------------------------------------------
# 11. destroy完了検証
# ・terraform applyがexit 0になっただけでは成功と判定しない。
# ・「Terraform stateが完全に空なら成功」という単純判定もしない。
#   消えるべきもの（管理対象aws_*リソース）がStateから消えていること、
#   かつ残すべきもの（Route53/IAM/OIDC/ACM/Budgets/Terraform State
#   バケット/Vercel Project等、Terraform管理外のリソース）が
#   引き続き存在していることの両方を確認する
# --------------------------------------------------
log_step "destroy完了検証"

# ・terraform applyの終了コードだけでなく、この検証結果も
#   最終的なスクリプトの終了コードに反映する（recover.shの
#   overall_ok方式と同じ考え方）。従来はここで見つかった不整合が
#   すべてlog_warnどまりで、画面上「destroyが完了しました」と
#   表示されながら実際には未解消の項目が残るケースを終了コードで
#   判別できなかった
overall_ok=true

remaining_managed=$( (cd "$TF_AWS_DIR" && terraform state list 2>/dev/null) | grep -c "^aws_" || true)
if [ "$remaining_managed" -eq 0 ]; then
  log_info "Terraform管理対象のAWSリソースはStateから0件（想定通り）"
else
  log_warn "Terraform Stateに管理対象リソースが${remaining_managed}件残っています（本来は0件のはず）"
  (cd "$TF_AWS_DIR" && terraform state list) | grep "^aws_" || true
  overall_ok=false
fi

log_step "保護対象リソースの存在確認（read-only、Terraform管理外）"

if aws route53 list-hosted-zones --query "HostedZones[?Name=='${FRONTEND_DOMAIN}.']" --output text 2>/dev/null | grep -q .; then
  log_info "  Route53 Hosted Zone（${FRONTEND_DOMAIN}）: 存在"
else
  log_warn "  Route53 Hosted Zone（${FRONTEND_DOMAIN}）: 確認できませんでした（要手動確認）"
  overall_ok=false
fi

if aws s3api head-bucket --bucket pitvia-terraform-state 2>/dev/null; then
  log_info "  Terraform State S3バケット（pitvia-terraform-state）: 存在"
else
  log_warn "  Terraform State S3バケット（pitvia-terraform-state）: 確認できませんでした（要手動確認）"
  overall_ok=false
fi

if aws iam get-role --role-name pitvia-github-actions-deploy-role >/dev/null 2>&1; then
  log_info "  IAM Role（pitvia-github-actions-deploy-role）: 存在"
else
  log_warn "  IAM Role（pitvia-github-actions-deploy-role）: 確認できませんでした（要手動確認）"
  overall_ok=false
fi

if aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList" --output text 2>/dev/null | grep -q .; then
  log_info "  GitHub OIDC Provider: 存在"
else
  log_warn "  GitHub OIDC Provider: 確認できませんでした（要手動確認）"
  overall_ok=false
fi

if aws budgets describe-budgets --account-id "$EXPECTED_AWS_ACCOUNT_ID" --query "Budgets" --output text 2>/dev/null | grep -q .; then
  log_info "  AWS Budgets: 存在"
else
  log_warn "  AWS Budgets: 確認できませんでした（要手動確認）"
  overall_ok=false
fi

log_step "消えるべきリソースの確認（read-only、代表的なものを個別確認）"

if aws rds describe-db-instances --db-instance-identifier "$RDS_IDENTIFIER" >/dev/null 2>&1; then
  log_warn "  RDS（${RDS_IDENTIFIER}）: まだ存在しています"
  overall_ok=false
else
  log_info "  RDS（${RDS_IDENTIFIER}）: 削除済み"
fi

if aws s3api head-bucket --bucket pitvia-prod-storage >/dev/null 2>&1; then
  log_warn "  S3バケット（pitvia-prod-storage）: まだ存在しています"
  overall_ok=false
else
  log_info "  S3バケット（pitvia-prod-storage）: 削除済み"
fi

if aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" >/dev/null 2>&1; then
  log_warn "  ECR（${ECR_REPOSITORY}）: まだ存在しています"
  overall_ok=false
else
  log_info "  ECR（${ECR_REPOSITORY}）: 削除済み"
fi

echo ""
echo "  次に行うこと:"
echo "  ・./scripts/prod/status.sh で状態を確認する"
echo "  ・復旧する場合は ./scripts/prod/recover.sh を実行する（docs/operations/recovery.md参照）"

if [ "$overall_ok" = true ]; then
  log_info "destroyが完了しました（Terraform管理対象0件、保護対象リソース健在をすべて確認済み）"
  exit 0
else
  log_warn "destroyは実行されましたが、検証で未解消の項目があります。上記の警告を確認してください"
  exit 1
fi
