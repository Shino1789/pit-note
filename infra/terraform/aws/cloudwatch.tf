# ==================================================
# CloudWatch Log Group (ECS)
# ・retention_in_daysは現状の実運用（無期限保持）に合わせて
#   あえて未設定のままにしている。保持期間を短縮する場合は
#   別途方針を決めたうえで明示的に設定すること
# ==================================================

resource "aws_cloudwatch_log_group" "api" {
  name = "/ecs/pitvia-api"

  tags = {
    Name = "pitvia-api-logs"
  }
}
