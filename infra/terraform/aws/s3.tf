# ==================================================
# S3 (画像等ストレージ)
# ・β版のため force_destroy = true とし、休止時に
#   destroy→再applyで作り直せる設計にする
# ・force_destroyはbucket内オブジェクトを道連れに削除するため、
#   本番相当データがある場合は事前のバックアップを必須とすること
# ==================================================

resource "aws_s3_bucket" "storage" {
  bucket        = "pitvia-prod-storage"
  force_destroy = true

  tags = {
    Name = "pitvia-prod-storage"
  }
}

resource "aws_s3_bucket_versioning" "storage" {
  bucket = aws_s3_bucket.storage.id

  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage" {
  bucket = aws_s3_bucket.storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# ==================================================
# Public Access Block
# ・GetObjectのみ公開するバケットポリシーを機能させるため、
#   BlockPublicPolicy / RestrictPublicBucketsのみfalseにする
# ・ACL経由の公開は引き続きブロックする
# ==================================================
resource "aws_s3_bucket_public_access_block" "storage" {
  bucket = aws_s3_bucket.storage.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "storage" {
  bucket = aws_s3_bucket.storage.id

  # ・GetObjectのみを匿名許可する、既存運用と同一のポリシー
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.storage.arn}/*"
      }
    ]
  })

  # Public Access Blockの設定が先に反映されていないと、
  # 公開ポリシーの適用自体が拒否されるため明示的に依存させる
  depends_on = [aws_s3_bucket_public_access_block.storage]
}
