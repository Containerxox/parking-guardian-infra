output "app_url" {
  description = "서비스 주소. Raspberry Pi 의 PG_SERVER_URL, 브라우저 접속."
  value       = "https://${aws_route53_record.app.name}"
}

output "alb_dns_name" {
  description = "ALB 의 DNS 이름(참고. 레코드가 가리키는 대상)."
  value       = data.aws_lb.alb.dns_name
}
