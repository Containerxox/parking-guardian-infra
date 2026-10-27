variable "aws_region" {
  description = "리전. 장비와 관리자가 모두 한국이므로 서울."
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "리소스 Name 태그와 Project 태그의 접두어."
  type        = string
  default     = "parking-guardian"
}

variable "vpc_cidr" {
  description = <<-EOT
    VPC 의 사설 IP 범위 (architecture.md 4.2). /16 = 65,536 개.
    EKS 의 VPC CNI 는 Pod 하나마다 VPC IP 를 하나씩 쓰므로 넉넉하게 잡는다.
    나중에 Private App Subnet /20 ×2, Public /24 ×2, DB /24 ×2 를 이 안에서 잘라 낸다.
  EOT
  type        = string
  default     = "10.0.0.0/16"
}
