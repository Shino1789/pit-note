# ==================================================
# Vercel Project
# ・管理対象はroot_directory / framework / build_command /
#   node_version / ignore_command / 環境変数 / ドメインのみ
#   （Issue #30スコープ）。それ以外のProject設定はTerraformで
#   明示的に管理せず、既存の実運用設定に委ねる
# ・git_repositoryは既存のリポジトリ連携を維持するため、
#   実際の連携内容と一致させて明示的に定義する
#   （省略するとリポジトリ連携解除の差分になり得るため）
# ==================================================

resource "vercel_project" "web" {
  name      = var.project_name
  framework = "nextjs"

  root_directory = "apps/web"
  node_version   = "24.x"

  # build_command / install_command は未設定（framework既定値を使用）
  ignore_command = "git diff HEAD^ HEAD --quiet -- ."

  # ・build_machine_type/resource_configはOptional+Computedのため
  #   省略可能だが、この2つは実機で既に値が入っており、省略すると
  #   環境変数追加時のフルアップデートで"(known after apply)"扱いに
  #   なり値が予測不能になるため、実機の値を明示して差分を無くす
  build_machine_type = "basic"

  resource_config = {
    fluid                    = true
    function_default_regions = ["iad1"]
  }

  git_repository = {
    type              = "github"
    repo              = var.git_repo
    production_branch = "main"
  }
}

# 本番カスタムドメイン（pitvia.vercel.appの既定ドメインはVercelが
# 自動割当するためTerraformでは管理しない）
resource "vercel_project_domain" "production" {
  project_id = vercel_project.web.id
  domain     = var.production_domain
}

# ==================================================
# 環境変数
# ・vercel_projectのenvironment属性（Set + Sensitive値）は、
#   既存の環境変数をimportしてもTerraform側が値を読み取れず、
#   apply時に「既存と同名の変数を新規作成しようとしてENV_CONFLICT
#   エラーになる」という実機検証済みの不具合があるため、
#   専用リソースvercel_project_environment_variableで個別管理する
# ==================================================
resource "vercel_project_environment_variable" "next_public_api_url" {
  project_id = vercel_project.web.id
  key        = "NEXT_PUBLIC_API_URL"
  value      = var.next_public_api_url
  target     = ["production", "preview", "development"]
  sensitive  = false
}
