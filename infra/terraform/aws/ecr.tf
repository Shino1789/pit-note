# ==================================================
# ECR (Backend Dockerイメージ)
# ・destroyするとイメージも失われるため、復旧時は
#   GitHub Actions deploy.ymlのworkflow_dispatchで
#   再pushする必要がある（docs/operations/recovery.md参照）
# ・force_delete = true: repository内にimageが残っていてもdestroy
#   できるようにする（既定はfalseで、image不在時のみ削除可能）。
#   β版のためimage保持は不要と割り切り、s3.tfのforce_destroy、
#   secrets.tfのrecovery_window_in_days=0と同じ方針で強制削除を許容する
# ==================================================

resource "aws_ecr_repository" "api" {
  name                 = "pitvia-api"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "pitvia-api"
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "最新10個のみ保持"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
