#!/bin/bash

# ==================================================
# 本番β環境 停止/破棄スクリプト
#
# AWS（RDS/S3/ECR/ECS/ALB/NAT Gateway等のTerraform管理リソース）を
# destroyし、Vercel Projectを一時非公開化（pause）する。
#
# 重要:
# ・RDSのデータ、S3の画像、ECRのDocker image、JWT secretは失われる
# ・Route53 Hosted Zone / IAM / OIDC / ACM / AWS Budgets / Vercel Project
#   自体は削除されない（Terraform管理外のため）
# ・Vercel pauseはfail-closed: pauseに失敗した場合、AWS destroyは
#   一切実行せず終了する（Frontendが公開されたままBackendだけ
#   destroyされる中途半端な状態を避けるため）
# ・実行には二段階の明示的確認が必須
#   1) スクリプト開始直後: 破棄する意思そのものを、固定フレーズの
#      完全一致入力で確認する（誤って実行しただけでは進まない）
#   2) terraform plan -destroy 実行後: 実際のdestroy対象を提示した
#      うえで、続行の意思を再確認する
#   どちらか一方でも拒否されたら、破壊的操作は一切行わず終了する
#
# 使い方:
#   ./scripts/prod/shutdown.sh            # 通常実行（二段階確認あり）
#   ./scripts/prod/shutdown.sh --dry-run  # destroy対象の確認のみ（確認・destroyともにしない）
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
# --------------------------------------------------
log_step "destroy対象一覧"
( cd "$TF_AWS_DIR" && terraform show -no-color "$DESTROY_PLAN_FILE" | grep -E "^  # " || true )
plan_summary=$( (cd "$TF_AWS_DIR" && terraform show -no-color "$DESTROY_PLAN_FILE") | grep -E "^Plan:" || echo "Plan: (取得失敗)")
echo ""
echo "  $plan_summary"

# destroy planにdestroy以外（想定外のadd/change/replacement）が
# 含まれていないことを確認する。想定外の変更が混ざっている場合は
# 破壊的操作を一切行わず停止する
if [[ "$plan_summary" != *"to destroy"* ]] || [[ "$plan_summary" == *"to add"* && "$plan_summary" != *"0 to add"* ]]; then
  die "想定外のplan結果です（destroy以外の変更が含まれています）" \
    "terraform show \"$DESTROY_PLAN_FILE\" の内容を手動で確認してください。"
fi

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
read -r -p "本当に続行しますか？ [yes/no]: " answer
if [ "$answer" != "yes" ]; then
  log_info "キャンセルしました（destroyは実行していません）"
  rm -f "$DESTROY_PLAN_FILE"
  exit 0
fi

# --------------------------------------------------
# 9. Vercel pause
# ・fail-closed: pauseに失敗した場合、AWS destroyは絶対に実行しない。
#   Frontend（Vercel）が公開されたままBackend（AWS）だけdestroyされる、
#   という中途半端な状態を避けるため
# --------------------------------------------------
log_step "Vercel Project を pause します"
if vercel project pause "$VERCEL_PROJECT_NAME" --yes 2>&1; then
  log_info "Vercel Projectをpauseしました"
else
  rm -f "$DESTROY_PLAN_FILE"
  die "Vercel Projectのpauseに失敗したためAWS destroyを中止します" \
    "Vercelの状態を確認し（vercel project inspect $VERCEL_PROJECT_NAME 等）、pause成功後に ./scripts/prod/shutdown.sh を再実行してください。"
fi

# --------------------------------------------------
# 10. AWS Terraform destroy
# ・事前に確認済みのplanファイルをそのまま適用する
#   （terraform destroy -auto-approve は直接実行しない）
# --------------------------------------------------
log_step "terraform apply（destroy plan）"
( cd "$TF_AWS_DIR" && terraform apply -no-color -input=false "$DESTROY_PLAN_FILE" )
rm -f "$DESTROY_PLAN_FILE"

# --------------------------------------------------
# 11. 完了確認
# --------------------------------------------------
log_step "destroy完了確認"
( cd "$TF_AWS_DIR" && terraform state list 2>/dev/null | wc -l | xargs -I{} echo "  残存Terraform管理リソース数: {}" ) || true

log_info "destroyが完了しました"
echo ""
echo "  次に行うこと:"
echo "  ・./scripts/prod/status.sh で状態を確認する"
echo "  ・復旧する場合は ./scripts/prod/recover.sh を実行する（docs/operations/recovery.md参照）"
