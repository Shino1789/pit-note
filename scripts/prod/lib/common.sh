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
    die "想定外のAWSアカウントです（期待値: $EXPECTED_AWS_ACCOUNT_ID / 実際: ${account_id}）" \
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

# Vercel Projectのpause状態を確認する（read-only）
# ・出力: "true"（pause済み） / "false"（未pause） / "unknown"（確認不可）
# ・`vercel project pause/resume`は非対話環境（TTY以外）から実行できない
#   仕様であることが実機確認済み（stdinへ確認文字列をpipeしても、
#   TTY判定の時点で内容を見ずに拒否される）。そのためpause/resumeの
#   実行そのものはscriptsから行わず、状態確認のみに用いる
get_vercel_paused_state() {
  local token="${VERCEL_API_TOKEN:-${VERCEL_TOKEN:-}}"
  if [ -z "$token" ]; then
    local auth_file="$HOME/Library/Application Support/com.vercel.cli/auth.json"
    if [ -f "$auth_file" ]; then
      token=$(jq -r '.token // empty' "$auth_file" 2>/dev/null || echo "")
    fi
  fi
  if [ -z "$token" ]; then
    echo "unknown"
    return
  fi

  local project_id
  project_id=$(terraform -chdir="$TF_VERCEL_DIR" output -raw project_id 2>/dev/null || echo "")
  if [ -z "$project_id" ]; then
    echo "unknown"
    return
  fi

  local paused
  paused=$(curl -s -H "Authorization: Bearer $token" \
    "https://api.vercel.com/v9/projects/$project_id" 2>/dev/null | jq -r '.paused // false' 2>/dev/null || echo "")
  case "$paused" in
    true) echo "true" ;;
    false) echo "false" ;;
    *) echo "unknown" ;;
  esac
}

# Vercel Projectをresumeする（production traffic再開。破壊的ではないが
# 課金・公開状態に影響するAPI呼び出しのため慎重に扱う）
# ・`vercel project resume ... --non-interactive`は使わない。CLI実装を
#   確認したところ、`resume`もcanPrompt(client)（=stdin.isTTYかつ
#   nonInteractiveでない場合のみtrue）がfalseだと対話確認をスキップできず
#   必ずaction_requiredで失敗する（--non-interactiveを外してもstdinが
#   TTYでない限り同様）。recover.shは自動ポーリング（CD完了待ち等）を
#   挟む半自動スクリプトであり、途中で対話プロンプトが挟まると
#   人が張り付いていない場合に無期限へハングしうるため採用しない。
#   get_vercel_paused_state()と同じ認証方式・project_id解決方式で、
#   REST API（POST /v1/projects/{id}/unpause）を直接呼び出す
#   （CLIのTTY依存を排除し、実行環境によらず決定的に動作させる）
# ・戻り値: 0=成功 / 1=失敗（呼び出し側でlog_warnし、手動resumeを促すこと）
# ・token/project_idの値は絶対にecho/logしない。レスポンスボディも
#   破棄する（-o /dev/null）
resume_vercel_project() {
  local token="${VERCEL_API_TOKEN:-${VERCEL_TOKEN:-}}"
  if [ -z "$token" ]; then
    local auth_file="$HOME/Library/Application Support/com.vercel.cli/auth.json"
    if [ -f "$auth_file" ]; then
      token=$(jq -r '.token // empty' "$auth_file" 2>/dev/null || echo "")
    fi
  fi
  if [ -z "$token" ]; then
    log_warn "Vercel APIトークンを取得できませんでした"
    return 1
  fi

  local project_id
  project_id=$(terraform -chdir="$TF_VERCEL_DIR" output -raw project_id 2>/dev/null || echo "")
  if [ -z "$project_id" ]; then
    log_warn "Vercel Project IDを取得できませんでした（terraform output）"
    return 1
  fi

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $token" \
    "https://api.vercel.com/v1/projects/$project_id/unpause")

  if [ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 300 ] 2>/dev/null; then
    return 0
  fi
  log_warn "Vercel resume APIが失敗しました（HTTP ${http_code}）"
  return 1
}

# ・curlがDNS解決失敗（exit code 6 = CURLE_COULDNT_RESOLVE_HOST）で
#   失敗した場合に限り、信頼できるパブリックDNS（Cloudflare 1.1.1.1）で
#   名前解決をやり直し、得られたIPで--resolveして再試行する。
#   実機で確認済み: curlのexit codeはDNS解決失敗のみ6、接続拒否は7、
#   タイムアウトは28であり、明確に区別できる。ALB等のIPアドレスは
#   destroy/recreateで変わりうるため、IPをコードにハードコードせず
#   毎回digで取得する（recover.sh実行環境のローカルDNSリゾルバが
#   一時的に不調でも、実際のAPI/インフラが正常なら誤ってhealth_ok=
#   falseにしないため）
# ・DNS以外の失敗（接続不可・タイムアウト等、exit code 6以外）や、
#   HTTP応答自体が取得できた場合（5xx等も含む）はフォールバックしない。
#   本当にAPI/インフラが落ちている場合まで「正常」に見せかけないため
# 引数: $1=URL, $2=--resolveに使うhost, $3=--resolveに使うport,
#       $4以降=curlへの追加オプション（例: -k, -H "Host: ..."）
# 出力: HTTPステータスコード（取得できなければ"000"）
# 戻り値: 0=何らかのHTTPステータスコードを取得できた（200かどうかは
#   呼び出し側で判定） / 1=DNS以外の理由も含め取得できなかった
http_code_with_dns_fallback() {
  local url="$1" resolve_host="$2" resolve_port="$3"
  shift 3
  local extra_args=("$@")

  local code curl_exit
  # ・extra_argsが空配列の場合（追加のcurlオプションを渡さない
  #   呼び出し）、bash 3.2ではset -u有効時に"${extra_args[@]}"の
  #   展開自体が"unbound variable"になる既知の不具合がある
  #   （bash 4.4で修正済みだが、macOS標準bashは3.2のまま）。
  #   ${array[@]+"${array[@]}"}という古典的なイディオムで、
  #   配列が空の場合は何も展開されず、要素がある場合は通常通り
  #   展開されるようにする
  code=$(curl -s -o /dev/null -w "%{http_code}" ${extra_args[@]+"${extra_args[@]}"} "$url")
  curl_exit=$?

  if [ "$curl_exit" -eq 0 ]; then
    echo "$code"
    return 0
  fi

  if [ "$curl_exit" -ne 6 ]; then
    # DNS以外の失敗（接続不可・タイムアウト等）はフォールバックしない
    echo "000"
    return 1
  fi

  # ・log_warn/log_infoの出力は標準出力(stdout)のため、この関数を
  #   $(...)で呼び出す側のHTTPステータスコードにログ文字列が混ざって
  #   しまわないよう、ここでは明示的にstderr(>&2)へ出す
  log_warn "  ローカルDNS解決に失敗しました（curl exit 6）。Cloudflare DNS（1.1.1.1）で再解決します" >&2
  local resolved_ip
  resolved_ip=$(dig @1.1.1.1 +short "$resolve_host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)

  if [ -z "$resolved_ip" ]; then
    log_warn "  Cloudflare DNSでも解決できませんでした" >&2
    echo "000"
    return 1
  fi

  log_info "  Cloudflare DNSでの解決結果（${resolved_ip}）でリトライします" >&2
  # ・上のcurl呼び出しと同じ理由で${array[@]+"${array[@]}"}イディオムを使う
  code=$(curl -s -o /dev/null -w "%{http_code}" --resolve "${resolve_host}:${resolve_port}:${resolved_ip}" ${extra_args[@]+"${extra_args[@]}"} "$url")
  curl_exit=$?

  if [ "$curl_exit" -ne 0 ]; then
    echo "000"
    return 1
  fi

  log_warn "  APIは正常に応答しましたが、ローカルDNS解決に問題がありました（実行環境固有の問題の可能性。Cloudflare DNS経由での疎通は確認できています）" >&2
  echo "$code"
  return 0
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

# --------------------------------------------------
# destroy retry設定
# ・無限retryは禁止。最大試行回数と累計経過時間の両方で上限を設ける
# --------------------------------------------------
DESTROY_MAX_ATTEMPTS=4          # 初回 + retry3回
DESTROY_MAX_ELAPSED_SECONDS=1800 # 累計30分
DESTROY_BACKOFF_BASE_SECONDS=30  # attempt毎のbackoff: 30s, 60s, 90s...
DESTROY_BACKOFF_MAX_SECONDS=90   # backoffの上限（それ以上は増やさない）

# --------------------------------------------------
# recover.sh: ECS/API/Frontend health確認のpolling設定
# ・GitHub Actions CD側で既にecs wait services-stableを経ているため、
#   ECSロールアウト確認（12.）は通常初回で安定しているはずだが、
#   単発チェックだと一時的な揺らぎ（タスク再起動直後等）を
#   誤って失敗と判定しうる。CD完了待ち（10.〜11.）と同じ
#   bounded retryの考え方を、短い時間幅で適用する
# ・ALB Target Health確認（13.）だけは別の専用予算
#   （ALB_TARGET_HEALTH_*、下記）を使う。deploy.ymlの
#   「Check ALB target health」はリトライなしの単発チェックであり、
#   ecs wait services-stableもECSレベルの安定（running=desired）を
#   保証するだけでALBのhealthy_threshold回連続成功までは保証しない
#   ため、この短い予算ではまだ不十分なことがある（詳細は下記参照）
# --------------------------------------------------
RECOVER_HEALTH_MAX_ATTEMPTS=10   # 初回 + retry9回
RECOVER_HEALTH_INTERVAL_SECONDS=10 # 試行間隔（最大で約100秒）

# --------------------------------------------------
# recover.sh: ALB Target Health確認（13.）専用のpolling設定
# ・ALB Target Group（alb.tf）のhealth_checkはinterval=30秒・
#   healthy_threshold=5回（連続成功）。AWSは登録直後にほぼ即座に
#   1回目のチェックを行い、以降interval秒ごとに実行するため、
#   理論上の最短所要時間は (healthy_threshold-1) × interval = 120秒
#   （1回目のチェックが即座に成功した最良ケース）。実際にはアプリ
#   （Spring Boot起動・DB接続確立・初回Flyway migration等）が
#   ヘルスチェックに応答できるようになるまでの起動時間が上乗せされる
#   ため、現実的には150〜250秒程度、場合によってはそれ以上かかりうる
#   （ecs.tfのhealth_check_grace_period_seconds=360もこれを見込んだ
#   既存の設計判断）。共通のRECOVER_HEALTH_*（最大約100秒）では
#   完全なdestroy→recovery直後（ALB Targetが真新しい登録）の
#   コールドスタートに対して不足するため、専用の長めの予算を設ける
# ・20回 × 15秒間隔 = 最大約300秒（5分）。理論最短120秒に対して
#   十分な余裕を持たせつつ、ECSのgrace period（360秒）は超えない
#   範囲に収め、本当に異常な場合も無駄に長時間待ちすぎないようにする
# --------------------------------------------------
ALB_TARGET_HEALTH_MAX_ATTEMPTS=20    # 初回 + retry19回
ALB_TARGET_HEALTH_INTERVAL_SECONDS=15 # 試行間隔（最大で約300秒）

# infra/terraform/aws が現在管理しているAWSリソースの「型」一覧。
# destroy planにこれ以外のaws_*リソースが含まれていた場合は、
# コードに想定外の変更が紛れ込んでいる可能性があるため停止する
# （docs/infrastructure/terraform.mdのImport一覧と対応）
EXPECTED_DESTROY_RESOURCE_TYPES=" aws_cloudwatch_log_group aws_db_instance aws_db_subnet_group aws_ecr_lifecycle_policy aws_ecr_repository aws_ecs_cluster aws_ecs_service aws_ecs_task_definition aws_internet_gateway aws_lb aws_lb_listener aws_lb_target_group aws_nat_gateway aws_route aws_route_table aws_route_table_association aws_s3_bucket aws_s3_bucket_policy aws_s3_bucket_public_access_block aws_s3_bucket_server_side_encryption_configuration aws_s3_bucket_versioning aws_secretsmanager_secret aws_security_group aws_subnet aws_vpc "

# terraform apply（destroy）が失敗した際のエラーメッセージを分類する。
# 出力: "retry"（一時的なエラー、retry候補） / "fatal"（即停止）
# ・retry対象は「既知の一時的エラー」に限定し、それ以外は
#   すべてfail-closed（fatal）とする（無条件retryは行わない）
# ・DependencyViolationは無条件retryにせず、IGW/NAT Gateway/EIP関連の
#   既知パターン（本番で実際に発生したケース）に一致する場合のみ
#   retry対象とする
classify_destroy_error() {
  local err="$1"

  # 即停止（設定ミス・権限・認証・state異常）を先に判定する
  if echo "$err" | grep -qE \
    'AccessDenied|UnauthorizedOperation|ExpiredToken|InvalidClientTokenId|AuthFailure|InvalidParameterValue|InvalidParameter([^V]|$)|Error acquiring the state lock|Invalid provider configuration|Unsupported argument|Unsupported block type|Reference to undeclared'; then
    echo "fatal"
    return
  fi

  # DependencyViolationは既知の一時的パターンに限定してretry対象にする
  if echo "$err" | grep -qE 'DependencyViolation'; then
    if echo "$err" | grep -qiE 'internet gateway|nat gateway|mapped public address|elastic ip|\bEIP\b'; then
      echo "retry"
    else
      echo "fatal"
    fi
    return
  fi

  # その他の既知の一時的エラー（DNS/ネットワーク/AWS API一時障害）
  if echo "$err" | grep -qE \
    'no such host|i/o timeout|connection reset|context deadline exceeded|RequestTimeout|Throttling|RequestLimitExceeded|TooManyRequestsException|InternalError|ServiceUnavailable'; then
    echo "retry"
    return
  fi

  # 既知パターンに一致しない正体不明のエラーは、安全側（fail-closed）
  # に倒して即停止する
  echo "fatal"
}

# destroy planが「純粋なdestroyのみ」であり、想定している管理対象
# リソース種別の範囲内であることを確認する（read-only、AWSは変更しない）
# 戻り値: 0=安全 / 1=想定外の内容あり（呼び出し側でdieすること）
validate_destroy_only_plan() {
  local plan_file="$1"
  local show_output
  show_output=$( (cd "$TF_AWS_DIR" && terraform show -no-color "$plan_file") )

  local summary
  summary=$(echo "$show_output" | grep -E "^Plan:" || echo "")
  echo "  ${summary:-Plan: (取得失敗)}"

  if [ -z "$summary" ]; then
    log_warn "plan summaryを取得できませんでした"
    return 1
  fi

  # add/changeが0件でなければNG（destroy以外の操作を許可しない）
  if [[ "$summary" != *"0 to add"* ]] || [[ "$summary" != *"0 to change"* ]]; then
    log_warn "destroy以外の変更（add/change）が含まれています"
    return 1
  fi

  # replace（作り直し）が1件でもあれば即NG
  if echo "$show_output" | grep -q "must be replaced"; then
    log_warn "resourceのreplace（作り直し）が含まれています"
    return 1
  fi

  # destroy対象のリソースアドレスが、既知の管理対象リソース種別の
  # 範囲内であることを確認する（「常に38件」ではなく「想定される
  # 型のdestroyだけが残っている」ことを確認する設計）
  local addr rtype
  while IFS= read -r addr; do
    [ -z "$addr" ] && continue
    rtype="${addr%%.*}"
    if [[ "$EXPECTED_DESTROY_RESOURCE_TYPES" != *" $rtype "* ]]; then
      log_warn "想定外のリソース種別がdestroy対象に含まれています: $addr"
      return 1
    fi
  done < <(echo "$show_output" | awk '/^  # / && /will be destroyed/ { print $2 }')

  return 0
}

# 破壊的操作の前に、単純なyes/noではなく完全一致の文字列入力を要求する
# ・入力が1文字でも異なれば即終了する（大文字小文字・空白も含めて完全一致）
# ・readをbareで呼ぶと、EOF/read失敗時（exit status != 0）にset -eで
#   即終了してしまい、"中止しました"の表示なしに終わる。shutdown.sh/
#   recover.shの他のread呼び出しと同じく、read自体をif条件に置いて
#   その挙動を吸収する
confirm_exact_phrase() {
  local phrase="$1"
  local answer
  if read -r -p "入力: " answer; then
    if [ "$answer" != "$phrase" ]; then
      log_info "入力が一致しなかったため中止しました（何も変更していません）"
      exit 0
    fi
  else
    log_info "入力を受け取れなかったため中止しました（何も変更していません）"
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
