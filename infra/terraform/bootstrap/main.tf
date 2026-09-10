# ==================================================
# Terraform State用 S3 Bucket (Bootstrap)
# ・infra/terraform/aws, infra/terraform/vercel の
#   backendとして使用するS3 bucketをここで先に作る
# ・循環参照を避けるため、このbootstrap自体はS3 backendを使わず
#   local stateのまま運用する（.gitignoreでコミットしない）
# ・一度作成したら、通常は再apply不要
# ==================================================

terraform {
  required_version = ">= 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.63"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"

  default_tags {
    tags = {
      Project   = "pitvia"
      ManagedBy = "terraform-bootstrap"
    }
  }
}

# ==================================================
# State用 S3 Bucket
# ・versioning有効化（誤ってstateを壊した際の復旧手段として）
# ・Public Access Blockで非公開を保証
# ・force_destroyは付けない（誤destroy時にstateごと消えるのを防ぐ）
# ==================================================
resource "aws_s3_bucket" "terraform_state" {
  bucket = "pitvia-terraform-state"

  tags = {
    Name = "pitvia-terraform-state"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket_name" {
  value = aws_s3_bucket.terraform_state.bucket
}
