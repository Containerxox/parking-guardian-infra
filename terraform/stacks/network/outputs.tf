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

# Subnet ID. for_each 리소스는 map 이므로 values() 로 리스트를 만든다. 키("a","c") 순으로 정렬된다.
output "public_subnet_ids" {
  description = "Public Subnet ID 2개(AZ a, c 순). cluster 스택(NAT Gateway 위치, EKS 클러스터 subnet)."
  value       = [for s in aws_subnet.public : s.id]
}

output "private_app_subnet_ids" {
  description = "Private App Subnet ID 2개. cluster 스택(EKS 노드 그룹)."
  value       = [for s in aws_subnet.private_app : s.id]
}

output "private_db_subnet_ids" {
  description = "Private DB Subnet ID 2개. data 스택(RDS 서브넷 그룹)."
  value       = [for s in aws_subnet.private_db : s.id]
}

# cluster 스택이 NAT Gateway 를 만든 뒤 이 테이블에 0.0.0.0/0 → NAT 경로(aws_route)를 추가한다.
output "private_app_route_table_id" {
  description = "Private App 라우트 테이블 ID. cluster 스택이 NAT 경로를 넣을 대상."
  value       = aws_route_table.private_app.id
}

# S3 prefix list ID. "S3 의 IP 대역" 을 가리키는 AWS 관리 목록(pl-xxxx).
# 노드 SG 의 아웃바운드를 좁힐 때 "S3 로 가는 443" 을 CIDR 대신 이 ID 로 적을 수 있다.
output "s3_endpoint_prefix_list_id" {
  description = "S3 Gateway Endpoint 의 prefix list ID. SG 규칙에서 S3 목적지를 지정할 때."
  value       = aws_vpc_endpoint.s3.prefix_list_id
}
