#!/bin/bash

# ==================================================
# 本番β環境 状態確認スクリプト（読み取り専用）
#
# AWS/Vercel/Terraformの現在状態を一覧表示する。
# ・破壊的な操作は一切行わない
# ・Secret valueは絶対に表示しない
#
# 使い方:
#   ./scripts/prod/status.sh
# ==================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_commands aws terraform jq curl vercel git

check_aws_identity

# --------------------------------------------------
# ECS
# --------------------------------------------------
log_step "ECS Service"

if svc_json=$(aws ecs describe-services \
  --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0]' --output json 2>/dev/null) && [ "$svc_json" != "null" ]; then

  echo "$svc_json" | jq -r '
    "  status         : \(.status // "N/A")",
    "  runningCount   : \(.runningCount // "N/A")",
    "  desiredCount   : \(.desiredCount // "N/A")",
    "  taskDefinition : \(.taskDefinition // "N/A")",
    "  rolloutState   : \(.deployments[0].rolloutState // "N/A")"
  '
else
  log_warn "ECS Service ($ECS_SERVICE) が見つかりません（未applyまたはdestroy済みの可能性）"
fi

# --------------------------------------------------
# ALB / Target Group
# --------------------------------------------------
log_step "ALB Target Health"

tg_arn=$(aws elbv2 describe-target-groups \
  --names "$TARGET_GROUP_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")

if [ -n "$tg_arn" ] && [ "$tg_arn" != "None" ]; then
  aws elbv2 describe-target-health \
    --target-group-arn "$tg_arn" \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State}' \
    --output table
else
  log_warn "Target Group ($TARGET_GROUP_NAME) が見つかりません"
fi

# --------------------------------------------------
# RDS
# --------------------------------------------------
log_step "RDS"

rds_status=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_IDENTIFIER" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "")

if [ -n "$rds_status" ] && [ "$rds_status" != "None" ]; then
  echo "  status: $rds_status"
else
  log_warn "RDS ($RDS_IDENTIFIER) が見つかりません（未applyまたはdestroy済みの可能性）"
fi

# --------------------------------------------------
# NAT Gateway
# --------------------------------------------------
log_step "NAT Gateway"

nat_state=$(aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=pitvia-nat-gateway" "Name=state,Values=pending,available,deleting" \
  --query 'NatGateways[0].State' --output text 2>/dev/null || echo "")

if [ -n "$nat_state" ] && [ "$nat_state" != "None" ]; then
  echo "  state: $nat_state"
else
  log_warn "NAT Gateway (pitvia-nat-gateway) が見つかりません"
fi

# --------------------------------------------------
# S3 / ECR
# --------------------------------------------------
log_step "S3 / ECR"

if aws s3api head-bucket --bucket pitvia-prod-storage >/dev/null 2>&1; then
  echo "  S3 bucket (pitvia-prod-storage) : 存在"
else
  log_warn "S3 bucket (pitvia-prod-storage) が見つかりません"
fi

if aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" >/dev/null 2>&1; then
  image_count=$(aws ecr list-images --repository-name "$ECR_REPOSITORY" --query 'length(imageIds)' --output text 2>/dev/null || echo "?")
  echo "  ECR repository ($ECR_REPOSITORY) : 存在（イメージ数: $image_count）"
else
  log_warn "ECR repository ($ECR_REPOSITORY) が見つかりません"
fi

# --------------------------------------------------
# Terraform plan状態（差分の有無のみ。値は出力しない）
# --------------------------------------------------
log_step "Terraform plan状態"

check_terraform_plan_status() {
  local dir="$1"
  local label="$2"
  local err_file
  err_file=$(mktemp "${TMPDIR:-/tmp}/pitvia-status-plan-err.XXXXXX")

  # ・set -e下で「終了コードを変数に受けてから分岐する」ため、
  #   コマンド単体ではなく `cmd || code=$?` の形で失敗を吸収する
  #   （素のコマンド失敗はerrexitで即終了してしまうため）
  local code=0
  ( cd "$dir" && \
    terraform init -input=false >/dev/null 2>&1 && \
    terraform plan -no-color -input=false -detailed-exitcode -out=/dev/null >/dev/null 2>"$err_file" \
  ) || code=$?

  case "$code" in
    0) echo "  $label : No changes（一致）" ;;
    2) echo "  $label : 差分あり（terraform planで詳細確認してください）" ;;
    *) log_warn "$label : plan実行に失敗しました（$(tail -1 "$err_file" 2>/dev/null)）" ;;
  esac
  rm -f "$err_file"
}

check_terraform_plan_status "$TF_AWS_DIR" "infra/terraform/aws"
check_terraform_plan_status "$TF_VERCEL_DIR" "infra/terraform/vercel"

# --------------------------------------------------
# Vercel pause状態
# --------------------------------------------------
log_step "Vercel"

vercel_token="${VERCEL_API_TOKEN:-${VERCEL_TOKEN:-}}"
if [ -z "$vercel_token" ]; then
  auth_file="$HOME/Library/Application Support/com.vercel.cli/auth.json"
  if [ -f "$auth_file" ]; then
    vercel_token=$(jq -r '.token // empty' "$auth_file" 2>/dev/null || echo "")
  fi
fi

if [ -n "$vercel_token" ]; then
  project_id=$(terraform -chdir="$TF_VERCEL_DIR" output -raw project_id 2>/dev/null || echo "")
  if [ -n "$project_id" ]; then
    paused=$(curl -s -H "Authorization: Bearer $vercel_token" \
      "https://api.vercel.com/v9/projects/$project_id" | jq -r '.paused // false')
    if [ "$paused" = "true" ]; then
      echo "  Project ($VERCEL_PROJECT_NAME) : ${COLOR_YELLOW}Paused${COLOR_RESET}"
    else
      echo "  Project ($VERCEL_PROJECT_NAME) : Active"
    fi
  else
    log_warn "Vercel Project IDを取得できませんでした（terraform outputを確認してください）"
  fi
else
  log_warn "Vercel APIトークンを取得できませんでした。'vercel project inspect $VERCEL_PROJECT_NAME' 等で手動確認してください"
fi

# --------------------------------------------------
# 疎通確認
# --------------------------------------------------
log_step "疎通確認"

api_code=$(curl -s -o /dev/null -w "%{http_code}" "https://api.${FRONTEND_DOMAIN}${API_HEALTH_PATH}" || echo "000")
echo "  API health (https://api.${FRONTEND_DOMAIN}${API_HEALTH_PATH}) : HTTP $api_code"

frontend_code=$(curl -s -o /dev/null -w "%{http_code}" "https://${FRONTEND_DOMAIN}" || echo "000")
echo "  Frontend   (https://${FRONTEND_DOMAIN})                       : HTTP $frontend_code"

log_step "確認完了"
