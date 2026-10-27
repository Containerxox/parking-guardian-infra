# --- nat ---
output "nat_public_ip" {
  description = "NAT 의 고정 공인 IP. 노드·Pod 의 아웃바운드 트래픽이 외부에 보이는 주소. 외부 서비스 IP 허용 목록용."
  value       = aws_eip.nat.public_ip
}
