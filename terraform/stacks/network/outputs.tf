# 다음 스택(data, cluster, platform)이 tfvars 로 받아 쓰는 값 (architecture.md 6.4 표).
# 스택 사이 값 전달은 terraform_remote_state 가 아니라 출력값 → 변수.

output "vpc_id" {
  description = "VPC ID. data(RDS 서브넷 그룹·SG), cluster(EKS), platform(ALB Controller) 스택이 쓴다."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR. SG 규칙이나 뒤 Phase 의 피어링 계획에 참고."
  value       = aws_vpc.this.cidr_block
}
