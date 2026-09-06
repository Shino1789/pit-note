# ==================================================
# Vercel Provider / Backend設定
# ・api_tokenはコード・tfvarsに書かず、VERCEL_API_TOKEN環境変数から
#   読み込ませる（providerのデフォルト動作）
# ==================================================

terraform {
  required_version = ">= 1.16.0"

  required_providers {
    vercel = {
      source  = "vercel/vercel"
      version = "~> 5.15"
    }
  }

  backend "s3" {
    bucket       = "pitvia-terraform-state"
    key          = "vercel/terraform.tfstate"
    region       = "ap-northeast-1"
    use_lockfile = true
  }
}

provider "vercel" {
  team = var.vercel_team_slug
}
