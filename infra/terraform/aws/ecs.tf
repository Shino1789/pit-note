# ==================================================
# ECS Cluster / Service / Task Definition
#
# Terraform と GitHub Actions CD (.github/workflows/deploy.yml) の責務分離:
# ・Terraformが管理: Cluster / Service本体設定（ネットワーク、ALB連携、
#   Circuit Breaker等）/ Task Definitionの初期雛形（cpu/memory/role/
#   environment/secrets/portMappings/logConfiguration）
# ・deploy.ymlが管理: 実際に稼働するcontainer image、および
#   そのimageを反映した新しいTask Definition revision
#
# aws_ecs_task_definition.container_definitions と
# aws_ecs_service.task_definition の両方に lifecycle.ignore_changes
# を設定し、deploy.ymlが作成した最新revisionをterraform applyが
# 巻き戻さないようにしている。
# インフラ的な変更（environment追加、role変更等）を行いたい場合は、
# 一時的にignore_changesを外してapplyし、その後元に戻す運用とする
# （docs/infrastructure/terraform.md参照）。
# ==================================================

resource "aws_ecs_cluster" "main" {
  name = "pitvia-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  configuration {
    execute_command_configuration {
      logging = "DEFAULT"
    }
  }

  tags = {
    Name = "pitvia-cluster"
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "pitvia-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = data.aws_iam_role.ecs_execution.arn
  task_role_arn            = data.aws_iam_role.ecs_task.arn

  # ・実機のTask Definitionに合わせて明示的に指定する。
  #   省略するとimport/plan時にruntime_platformの削除＝
  #   force replacement（Task Definitionの意図しない置き換え）
  #   として検出されるため必須
  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  # ・imageは初回apply時点の雛形。以降はdeploy.ymlが更新する
  container_definitions = jsonencode([
    {
      name      = "pitvia-api"
      image     = "${aws_ecr_repository.api.repository_url}:latest"
      essential = true
      portMappings = [
        {
          name          = "pitvia-api-8080-tcp"
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]
      environment = [
        { name = "SERVER_PORT", value = "8080" },
        { name = "COOKIE_DOMAIN", value = ".pitviaapp.com" },
        { name = "STORAGE_PROVIDER", value = "s3" },
        { name = "DB_PORT", value = "5432" },
        { name = "STORAGE_BUCKET", value = aws_s3_bucket.storage.bucket },
        { name = "SPRING_PROFILES_ACTIVE", value = "prod" },
        { name = "DB_NAME", value = "pitvia" },
        { name = "JWT_EXPIRES", value = "15m" },
        { name = "DB_HOST", value = aws_db_instance.main.address },
        { name = "STORAGE_REGION", value = var.aws_region },
        { name = "FRONTEND_URL", value = "https://pitviaapp.com" },
        { name = "DB_USERNAME", value = "pitvia" },
        { name = "JWT_REFRESH_EXPIRES", value = "7d" },
        { name = "STORAGE_PUBLIC_BASE_URL", value = "https://${aws_s3_bucket.storage.bucket}.s3.${var.aws_region}.amazonaws.com" },
      ]
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password::"
        },
        {
          name      = "JWT_SECRET_KEY"
          valueFrom = "${aws_secretsmanager_secret.jwt.arn}:JWT_SECRET_KEY::"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
          "awslogs-create-group"  = "true"
        }
      }
    }
  ])

  tags = {
    Name = "pitvia-api"
  }

  lifecycle {
    ignore_changes = [container_definitions]
  }
}

resource "aws_ecs_service" "api" {
  name            = "pitvia-api-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.ecs_desired_count

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 0
  }

  network_configuration {
    subnets          = [aws_subnet.private_1a.id, aws_subnet.private_1c.id]
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "pitvia-api"
    container_port   = 8080
  }

  health_check_grace_period_seconds = 360

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100
  enable_ecs_managed_tags            = true

  tags = {
    Name = "pitvia-api-service"
  }

  depends_on = [aws_lb_listener.https]

  lifecycle {
    ignore_changes = [task_definition]
  }
}
