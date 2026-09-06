#!/bin/bash

# ==================================================
# 本番β環境 運用スクリプト共通ライブラリ
#
# scripts/prod/shutdown.sh / recover.sh / status.sh から
# `source`して使う。単体では実行しない。
#
# ・Secret valueは絶対にecho/logしない
# ・破壊的操作の前に必ずconfirmを通す設計を前提とする
# ==================================================

set -euo pipefail

# --------------------------------------------------
# パス解決
# ・呼び出し元スクリプトの $SCRIPT_DIR を基準にする
#   （実行時のカレントディレクトリに依存しない）
# ・このファイルは scripts/prod/lib/common.sh に配置されているため、
#   リポジトリルートは3階層上（lib → prod → scripts → root）
# --------------------------------------------------
PROD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PROD_LIB_DIR/../../.." && pwd)"

TF_BOOTSTRAP_DIR="$REPO_ROOT/infra/terraform/bootstrap"
TF_AWS_DIR="$REPO_ROOT/infra/terraform/aws"
TF_VERCEL_DIR="$REPO_ROOT/infra/terraform/vercel"

# --------------------------------------------------
# 固定値
# ・想定外のAWSアカウント/リージョンで実行してしまう事故を防ぐため、
#   infra/terraform/aws/variables.tf の既定値と同じ値を明示する
# --------------------------------------------------
EXPECTED_AWS_ACCOUNT_ID="956118719101"
EXPECTED_AWS_REGION="ap-northeast-1"

ECS_CLUSTER="pitvia-cluster"
ECS_SERVICE="pitvia-api-service"
ECR_REPOSITORY="pitvia-api"
RDS_IDENTIFIER="pitvia-db"
ALB_NAME="pitvia-alb"
TARGET_GROUP_NAME="pitvia-api-tg"
JWT_SECRET_ID="pitvia/prod/jwt-secret-key"
VERCEL_PROJECT_NAME="pitvia"
ROUTE53_RECORD_NAME="api.pitviaapp.com"
FRONTEND_DOMAIN="pitviaapp.com"
API_HEALTH_PATH="/api/v1/health"

# --------------------------------------------------
# 出力ヘルパー（色付け。TTY以外では無色）
# --------------------------------------------------
if [ -t 1 ]; then
  COLOR_RED=$'\033[31m'
  COLOR_GREEN=$'\033[32m'
  COLOR_YELLOW=$'\033[33m'
  COLOR_BLUE=$'\033[34m'
  COLOR_BOLD=$'\033[1m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_RED=""; COLOR_GREEN=""; COLOR_YELLOW=""; COLOR_BLUE=""; COLOR_BOLD=""; COLOR_RESET=""
fi

log_step()  { echo ""; echo "${COLOR_BOLD}${COLOR_BLUE}==> $*${COLOR_RESET}"; }
log_info()  { echo "${COLOR_GREEN}[INFO]${COLOR_RESET} $*"; }
log_warn()  { echo "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
log_error() { echo "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2; }

# 失敗時に「次に何をすべきか」を必ず添えて終了する
die() {
  log_error "$1"
  if [ -n "${2:-}" ]; then
    echo ""
    echo "${COLOR_YELLOW}次に行うべきこと:${COLOR_RESET}"
    echo "  $2"
  fi
  exit 1
}

# --------------------------------------------------
# 事前チェック
# --------------------------------------------------

# 必要なCLIツールが揃っているか確認する
require_commands() {
  local missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "必要なコマンドが見つかりません: ${missing[*]}" \
      "上記コマンドをインストールしてから再実行してください。"
  fi
}

# AWSアカウント/リージョンが想定通りであることを確認する
# ・誤って別アカウント/別プロファイルで実行する事故を防ぐ
check_aws_identity() {
  log_step "AWSアカウント/リージョン確認"

  local identity account_id
  identity=$(aws sts get-caller-identity --output json) || \
    die "AWS認証情報を取得できませんでした" "aws configure / SSOログイン等でAWS認証情報を設定してください。"

  account_id=$(echo "$identity" | jq -r '.Account')
  local caller_arn
  caller_arn=$(echo "$identity" | jq -r '.Arn')

  echo "  Account : $account_id"
  echo "  Caller  : $caller_arn"
  echo "  Region  : ${AWS_REGION:-$EXPECTED_AWS_REGION}"

  if [ "$account_id" != "$EXPECTED_AWS_ACCOUNT_ID" ]; then
    die "想定外のAWSアカウントです（期待値: $EXPECTED_AWS_ACCOUNT_ID / 実際: $account_id）" \
      "正しいAWSプロファイル/認証情報に切り替えてから再実行してください。"
  fi

  export AWS_REGION="$EXPECTED_AWS_REGION"
  log_info "AWSアカウント/リージョンを確認しました"
}

# Vercel CLIが認証済みであることを確認する（read-only）
check_vercel_auth() {
  log_step "Vercel認証確認"

  if ! vercel whoami >/dev/null 2>&1; then
    die "Vercel CLIが認証されていません" "vercel login を実行してから再実行してください。"
  fi
  log_info "Vercel CLIの認証を確認しました"
}

# 現在のgit branch/作業状態を表示する（判断材料の提示のみ。ブロックはしない）
show_git_context() {
  log_step "Gitブランチ/作業状態確認"

  local branch
  branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "unknown")
  echo "  現在のブランチ: $branch"

  if ! git -C "$REPO_ROOT" diff --quiet -- infra/terraform 2>/dev/null || \
     ! git -C "$REPO_ROOT" diff --cached --quiet -- infra/terraform 2>/dev/null; then
    log_warn "infra/terraform 配下にコミットされていない変更があります。"
    log_warn "意図した内容か必ず確認してから続行してください（git status / git diff）。"
  fi
}

# Terraform backendがS3であること（bootstrapはLocal State）を確認する
check_terraform_backend() {
  local dir="$1"
  local expect="$2" # "s3" or "local"

  local main_tf="$dir/main.tf"
  [ -f "$main_tf" ] || die "Terraform設定が見つかりません: $main_tf" "infra/terraform配下の構成を確認してください。"

  if [ "$expect" = "s3" ]; then
    grep -q 'backend "s3"' "$main_tf" || \
      die "$dir がS3 backend構成になっていません" "infra/terraform/*/main.tf のbackend設定を確認してください。"
  else
    grep -q 'backend "s3"' "$main_tf" && \
      die "$dir はLocal State運用のはずですが、S3 backendが設定されています" "infra/terraform/bootstrap/README.mdの設計意図を確認してください。"
  fi
}

# 破壊的操作の前に、単純なyes/noではなく完全一致の文字列入力を要求する
# ・入力が1文字でも異なれば即終了する（大文字小文字・空白も含めて完全一致）
confirm_exact_phrase() {
  local phrase="$1"
  local answer
  read -r -p "入力: " answer
  if [ "$answer" != "$phrase" ]; then
    log_info "入力が一致しなかったため中止しました（何も変更していません）"
    exit 0
  fi
}

# Secretを画面・ログに一切出さずに、安全にSecrets Managerへ投入する
# ・引数の値は決してechoしない。呼び出し側でも変数展開をログに出さないこと
put_secret_value_safely() {
  local secret_id="$1"
  local json_value="$2" # 例: '{"JWT_SECRET_KEY":"..."}'

  local tmp_file
  tmp_file=$(mktemp "${TMPDIR:-/tmp}/pitvia-secret.XXXXXX")
  chmod 600 "$tmp_file"
  # trap内でも変数展開されるよう、この関数内で完結させる
  # shellcheck disable=SC2064
  trap "shred -u '$tmp_file' 2>/dev/null || rm -f '$tmp_file'" RETURN

  printf '%s' "$json_value" > "$tmp_file"

  aws secretsmanager put-secret-value \
    --secret-id "$secret_id" \
    --secret-string "file://$tmp_file" \
    >/dev/null
}
