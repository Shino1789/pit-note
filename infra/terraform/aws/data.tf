# ==================================================
# 既存リソース参照 (Terraform管理外)
# ・IAM Role / ACM証明書は既存のものをそのまま参照する
# ・Terraformでは作成・変更・削除を一切行わない
# ==================================================

# ECS Task Execution Role（ECR pull, Secrets Manager read, CloudWatch Logs書き込み）
data "aws_iam_role" "ecs_execution" {
  name = var.ecs_execution_role_name
}

# ECS Task Role（S3アクセス）
data "aws_iam_role" "ecs_task" {
  name = var.ecs_task_role_name
}

# api.pitviaapp.com 用の既存ACM証明書
# ・DNS検証済み・ISSUED状態のものだけを対象にする
data "aws_acm_certificate" "api" {
  domain      = var.acm_certificate_domain
  statuses    = ["ISSUED"]
  most_recent = true
}
