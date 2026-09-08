# ==================================================
# RDS PostgreSQL
# ・β版のため deletion_protection = false, skip_final_snapshot = true
#   とし、休止時にdestroy→再applyで作り直せる設計にする
# ・master passwordはmanage_master_user_password機能でRDSが
#   Secrets Managerを自動管理する。Secret自体を別resourceとして
#   Terraformで管理しない（値もコードに一切書かない）
# ==================================================

resource "aws_db_subnet_group" "main" {
  name        = "pitvia-db-subnet-group"
  description = "Pitvia DB subnet group"
  subnet_ids  = [aws_subnet.private_1a.id, aws_subnet.private_1c.id]

  tags = {
    Name = "pitvia-db-subnet-group"
  }
}

resource "aws_db_instance" "main" {
  identifier     = "pitvia-db"
  engine         = "postgres"
  engine_version = "17.11"
  instance_class = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  username                    = "pitvia"

# RDS新規作成時にアプリケーション接続先の pitvia DB を自動作成する。
# 既存インスタンスでは変更不可（replacement）となるため、
# 既存RDSへの適用は行わず、次回のdestroy→recovery時に反映する。
  db_name                     = "pitvia"
  manage_master_user_password = true

  backup_retention_period      = 1
  backup_window                = "18:02-18:32"
  maintenance_window           = "tue:13:06-tue:13:36"
  auto_minor_version_upgrade   = true
  copy_tags_to_snapshot        = false
  performance_insights_enabled = true

  # ==================================================
  # β版データ削除方針
  # ・休止時にdestroyしてもデータ喪失を許容する
  # ==================================================
  deletion_protection = false
  skip_final_snapshot = true

  tags = {
    Name = "pitvia-db"
  }
}
