# ==================================================
# ALB / Target Group / Listener
# ・ACM証明書はTerraform管理外の既存証明書をdata sourceで参照する
#   （data.tf）。証明書自体の作成・削除は行わない
# ・ALBを再作成するとDNS Nameが変わるため、Route53のAliasを
#   手動更新する必要がある（docs/operations/recovery.md参照）
# ==================================================

resource "aws_lb" "main" {
  name               = "pitvia-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_1a.id, aws_subnet.public_1c.id]

  idle_timeout               = 60
  enable_deletion_protection = false

  tags = {
    Name = "pitvia-alb"
  }

  # ・internet-facing ALBはENIにpublic IPv4アドレスを持つため、
  #   AWS公式仕様上（DetachInternetGateway API: "The VPC must not
  #   contain any running instances with Elastic IP addresses or
  #   public IPv4 addresses."）、Internet Gatewayのdetachをブロックしうる。
  #   Terraformコード上はALBがIGWを直接参照していないため、暗黙の
  #   依存関係が存在せず、destroy時にIGWがALBより先に破棄されようと
  #   して DependencyViolation で失敗する事故が実機で発生した。
  #   aws_nat_gateway.main（同ファイル群内）と同様に、明示的な
  #   depends_onでIGWとの順序を保証する
  #   - CREATE: IGW → ALB
  #   - DESTROY: ALB（および依存するhttps/httpリスナー・ECS Service）→ IGW
  depends_on = [aws_internet_gateway.main]
}

resource "aws_lb_target_group" "api" {
  name             = "pitvia-api-tg"
  port             = 8080
  protocol         = "HTTP"
  protocol_version = "HTTP1"
  vpc_id           = aws_vpc.main.id
  target_type      = "ip"

  health_check {
    protocol            = "HTTP"
    path                = "/api/v1/health"
    port                = "traffic-port"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    matcher             = "200"
  }

  deregistration_delay = 300

  stickiness {
    type    = "lb_cookie"
    enabled = false
  }

  tags = {
    Name = "pitvia-api-tg"
  }
}

# HTTP:80 → HTTPS:443 リダイレクト
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS:443（既存ACM証明書をアタッチ）
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
  certificate_arn   = data.aws_acm_certificate.api.arn

  # ・実機のListenerが保持する明示的なforwardブロック（単一Target
  #   Group + weight + stickiness設定）に合わせて記述する。
  #   target_group_arnの省略形にすると、import/plan時に既存の
  #   forwardブロックの削除として検出されてしまうため
  default_action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.api.arn
        weight = 1
      }

      stickiness {
        enabled  = false
        duration = 3600
      }
    }
  }
}
