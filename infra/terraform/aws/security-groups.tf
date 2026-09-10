# ==================================================
# Security Group
# 3層構成: ALB → ECS → RDS
# ==================================================

resource "aws_security_group" "alb" {
  name        = "pitvia-alb-sg"
  description = "Allow HTTPS access to Pitvia ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Public HTTP access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Public HTTPS access"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "pitvia-alb-sg"
  }
}

resource "aws_security_group" "ecs" {
  name        = "pitvia-ecs-sg"
  description = "ECS inbound from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "ALB to ECS 8080"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "pitvia-ecs-sg"
  }
}

resource "aws_security_group" "rds" {
  name        = "pitvia-rds-sg"
  description = "Allow PostgreSQL from ECS only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Allow PostgreSQL from ECS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "pitvia-rds-sg"
  }
}
