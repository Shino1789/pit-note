# ==================================================
# Outputs
# ・再構築後の後続作業（Route53手動更新、deploy.yml実行等）で
#   参照する値のみを出力する
# ・Secret値は絶対に出力しない
# ==================================================

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "alb_dns_name" {
  description = "ALBのDNS名。Route53のAliasレコードと異なる場合は手動更新が必要"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Route53 AliasレコードのAliasTarget.HostedZoneIdに使用するALBのZone ID"
  value       = aws_lb.main.zone_id
}

output "ecr_repository_url" {
  description = "ECRリポジトリURL。deploy.ymlのdocker pushで使用する"
  value       = aws_ecr_repository.api.repository_url
}

output "ecs_cluster_name" {
  description = "ECSクラスタ名。deploy.ymlの参照値と一致すること"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECSサービス名。deploy.ymlの参照値と一致すること"
  value       = aws_ecs_service.api.name
}

output "rds_endpoint" {
  description = "RDSエンドポイント"
  value       = aws_db_instance.main.address
}

output "rds_master_user_secret_arn" {
  description = "RDSマスターパスワードを保持するSecrets ManagerのARN（値は出力しない）"
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "jwt_secret_arn" {
  description = "JWT SecretのARN（値は出力しない）。再構築後は値の再投入が必要"
  value       = aws_secretsmanager_secret.jwt.arn
}

output "s3_bucket_name" {
  description = "整備写真保存用S3バケット名"
  value       = aws_s3_bucket.storage.bucket
}
