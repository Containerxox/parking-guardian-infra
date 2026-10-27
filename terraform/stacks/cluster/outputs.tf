# --- nat ---
output "nat_public_ip" {
  description = "NAT 의 고정 공인 IP. 노드·Pod 의 아웃바운드 트래픽이 외부에 보이는 주소. 외부 서비스 IP 허용 목록용."
  value       = aws_eip.nat.public_ip
}

# --- eks ---
output "cluster_name" {
  description = "EKS 클러스터 이름. platform 스택(helm provider), config 리포(aws eks update-kubeconfig --name)."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "API 서버 엔드포인트. platform 스택 helm/kubernetes provider."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "API 서버 CA(base64). platform 스택 provider."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS 가 만든 클러스터 SG. 컨트롤 플레인 ENI 와 노드에 붙는다(network 의 node SG 와 별개)."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "cluster_version" {
  description = "실제 Kubernetes 버전(플랫폼 버전은 콘솔)."
  value       = aws_eks_cluster.this.version
}
