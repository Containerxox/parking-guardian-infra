# ---------------------------------------------------------------------------
# DNS 와 인증서 (architecture.md 4.9). 서비스 주소는 parking.<도메인> 하나.
#
# 도메인 자체는 Terraform 밖이다. 이 계정은 Free 플랜이라 Route 53 Domains(등록)를 쓸 수 없어 외부 등록기관에서 산다.
# 역할 분담:
#   등록기관   도메인 소유권, "이 도메인의 네임서버는 ○○" 한 줄(NS 위임)
#   Route 53   영역(Hosted Zone): 실제 레코드를 담는 곳. 영역을 만들면 AWS 가 네임서버 4개를 배정한다
#   ACM        parking.<도메인> 의 TLS 인증서. 소유 증명은 영역에 CNAME 하나를 두는 "DNS 검증"
#
# 순서: ① 영역 apply → ② 출력된 NS 4개를 등록기관에 등록(수동) → ③ 전파 뒤 ACM 검증이 통과해 ISSUED
# ①~③ 은 한 apply 안에서 진행되지만, ② 가 끝나기 전에는 aws_acm_certificate_validation 이 검증을 기다리다 타임아웃(기본 75분)으로 실패한다.
# 그래서 처음엔 영역만 apply 하고(-target), NS 등록 뒤 전체를 apply 한다(README).
#
# 비용: 영역 월 $0.50 + 쿼리 100만 건당 $0.40. ACM 퍼블릭 인증서는 무료(자동 갱신).
# ALB 를 가리키는 Alias 레코드는 여기 없다. ALB 가 생긴 뒤 dns-record 스택이 만든다(결정 20).
# ---------------------------------------------------------------------------

# < Route 53 Hosted Zone > 퍼블릭 영역. 만들면 NS 4개와 SOA 레코드가 자동으로 들어간다.
resource "aws_route53_zone" "this" {
  name    = var.domain_name
  comment = "Parking Guardian. Registrar NS must point here."

  tags = {
    Name = var.domain_name
  }
}

# < ACM 인증서 > 리전 리소스. ALB 가 서울에 있으므로 서울(ap-northeast-2)에서 발급받는다 (CloudFront 라면 us-east-1).
resource "aws_acm_certificate" "app" {
  domain_name       = "${var.app_hostname}.${var.domain_name}" # parking.example.com 하나. 와일드카드 없음
  validation_method = "DNS"                                    # 영역에 CNAME 을 두면 ACM 이 확인한다. 이메일 검증은 수동이라 쓰지 않는다

  # 갱신·재발급 때 새 인증서를 먼저 만들고 옛것을 지운다. ALB 리스너가 참조 중인 인증서를 먼저 지우면 실패하기 때문.
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.app_hostname}.${var.domain_name}"
  }
}

# < 검증 레코드 > ACM 이 "이 CNAME 을 영역에 넣어라" 고 알려 주는 값(domain_validation_options)을 그대로 레코드로 만든다.
# 도메인이 하나라 옵션도 하나지만, 여러 도메인(SAN)으로 늘어날 때를 대비해 for_each 로 쓴다.
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true # 재발급으로 값이 바뀌면 덮어쓴다
}

# < 검증 완료 대기 > 실제 리소스를 만들지 않는다. ACM 상태가 ISSUED 가 될 때까지 apply 를 붙잡아 두고,
# 뒤 스택(config 리포 Ingress)이 쓰는 ARN 은 이 리소스의 것을 출력해 "검증된 인증서" 만 넘어가게 한다.
resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}
