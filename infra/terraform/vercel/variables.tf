# ==================================================
# Variables
# ==================================================

variable "vercel_team_slug" {
  description = "VercelチームSlug（実質的な個人アカウントの既定Team）"
  type        = string
  default     = "shino1789s-projects"
}

variable "project_name" {
  description = "Vercel Project名"
  type        = string
  default     = "pitvia"
}

variable "git_repo" {
  description = "連携するGitHubリポジトリ（owner/repo）"
  type        = string
  default     = "Shino1789/pitvia"
}

variable "production_domain" {
  description = "本番用カスタムドメイン"
  type        = string
  default     = "pitviaapp.com"
}

variable "next_public_api_url" {
  description = "フロントエンドから参照するAPIベースURL（非機密値。docs/deployment/environment-variables.md参照）"
  type        = string
  default     = "https://api.pitviaapp.com/api/v1"
}
