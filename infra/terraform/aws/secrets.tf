# ==================================================
# Secrets Manager (JWT Secret)
# ・aws_secretsmanager_secret（メタデータ）のみ管理する
# ・aws_secretsmanager_secret_versionは作成しない
#   （Secret値をTerraformコード/tfstateに一切持たせないため）
# ・値の投入・再投入は手動、または安全なCLI操作で行う
#   （docs/operations/recovery.md参照）
# ・RDSのmaster password用Secretはaws_db_instanceの
#   manage_master_user_password機能に内包されるため、
#   ここでは別resourceとして扱わない
# ==================================================

resource "aws_secretsmanager_secret" "jwt" {
  name        = "pitvia/prod/jwt-secret-key"
  description = "Pitvia production JWT signing secret"

  # β版のため、休止時にdestroy→再作成する運用を許容する。
  # 30日間の復旧猶予を待たずに同名Secretを再作成できるようにする
  recovery_window_in_days = 0

  tags = {
    Name = "pitvia-jwt-secret-key"
  }
}
