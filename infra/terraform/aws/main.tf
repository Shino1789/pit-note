# ==================================================
# Terraform / AWS Provider 設定
# ==================================================

terraform {
  required_version = ">= 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.63"
    }
  }

  # ==================================================
  # State管理 (S3 backend)
  # ・backend用S3 bucketは infra/terraform/bootstrap で別管理
  # ・state lockingはS3ネイティブロック(use_lockfile)を使用し、
  #   DynamoDB lock tableは新規作成しない
  # ==================================================
  backend "s3" {
    bucket       = "pitvia-terraform-state"
    key          = "aws/terraform.tfstate"
    region       = "ap-northeast-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "pitvia"
      ManagedBy = "terraform"
    }
  }
}
