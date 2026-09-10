# ==================================================
# 変数定義
# ==================================================

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "account_id" {
  description = "AWSアカウントID"
  type        = string
  default     = "956118719101"
}

variable "vpc_cidr" {
  description = "VPCのCIDRブロック"
  type        = string
  default     = "10.0.0.0/16"
}

# ==================================================
# ECS Serviceの稼働状態
# ・休止したい場合は0に変更してapplyする
# ・0にしてもECS Cluster/Service自体は削除されず、
#   Fargateの課金のみ発生しなくなる
# ==================================================
variable "ecs_desired_count" {
  description = "ECS Serviceの起動タスク数（休止時は0にする）"
  type        = number
  default     = 1
}

# ==================================================
# 既存リソース参照用（Terraform管理外リソースの識別子）
# ==================================================
variable "acm_certificate_domain" {
  description = "既存ACM証明書のドメイン名（data sourceで参照するのみ、作成・削除はしない）"
  type        = string
  default     = "api.pitviaapp.com"
}

variable "ecs_execution_role_name" {
  description = "既存ECS Execution Roleの名前（data sourceで参照するのみ）"
  type        = string
  default     = "pitvia-ecs-execution-role"
}

variable "ecs_task_role_name" {
  description = "既存ECS Task Roleの名前（data sourceで参照するのみ）"
  type        = string
  default     = "pitvia-ecs-task-role"
}
