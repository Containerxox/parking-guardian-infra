# < 조회 1 > Hosted Zone. data 스택이 만든 영역을 이름으로 찾는다(ID 를 tfvars 로 옮기지 않아도 된다).
data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

# < 조회 2 > ALB. config 리포 ingress.yaml 의 alb.ingress.kubernetes.io/load-balancer-name: parking-guardian 이 이 이름을 보장한다.
# ALB 가 없으면 여기서 "no matching LoadBalancer found" 로 plan 이 실패한다 → Ingress 가 먼저 적용됐는지 확인.
data "aws_lb" "alb" {
  name = var.project_name
}

# < Alias 레코드 > parking.<도메인> → ALB.
# Alias 는 CNAME 과 달리 ① 영역 꼭대기(apex)에도 쓸 수 있고 ② 쿼리 과금이 없고 ③ ALB 의 IP 변화를 Route 53 이 따라간다.
# zone_id 는 "우리 영역" 이 아니라 "ALB 가 속한 ELB 의 Hosted Zone ID"(리전별 고정값)다. data "aws_lb" 가 알려 준다.
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = "${var.app_hostname}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = data.aws_lb.alb.dns_name
    zone_id                = data.aws_lb.alb.zone_id
    evaluate_target_health = true # ALB 의 타깃이 모두 unhealthy 면 레코드를 응답하지 않는다(장애 시 빈 응답. 레코드 하나라 실질 효과는 작다)
  }
}
