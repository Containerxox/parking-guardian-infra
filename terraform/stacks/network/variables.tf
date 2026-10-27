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

# ---------------------------------------------------------------------------
# Subnet CIDR (architecture.md 4.2). 키는 AZ 접미어("a", "c"), 값은 CIDR.
# 키를 AZ 접미어로 둔 이유: for_each 가 이 키로 리소스 주소를 만든다
# (aws_subnet.public["a"]). 나중에 AZ 를 추가해도 기존 Subnet 주소가 안 바뀐다.
# (리스트 + count 였다면 순서가 바뀔 때 Subnet 이 재생성된다.)
#
# 10.0.0.0/16 안의 배치:
#   10.0.0.0/20   App a   (10.0.0.0  ~ 10.0.15.255,  4,096 개)
#   10.0.16.0/20  App c   (10.0.16.0 ~ 10.0.31.255,  4,096 개)
#   10.0.32.0/24  Public a (256 개)
#   10.0.33.0/24  Public c
#   10.0.40.0/24  DB a
#   10.0.41.0/24  DB c
#   10.0.48.0 ~ 10.0.255.255 는 비워 둔다(뒤 Phase 의 추론 서비스 등).
# ---------------------------------------------------------------------------
variable "private_app_subnet_cidrs" {
  description = "Private App Subnet. EKS 노드와 Pod. VPC CNI 가 Pod 마다 IP 를 쓰므로 /20 으로 크게."
  type        = map(string)
  default = {
    a = "10.0.0.0/20"
    c = "10.0.16.0/20"
  }
}

variable "public_subnet_cidrs" {
  description = "Public Subnet. ALB 와 NAT Gateway 만 들어가므로 /24 로 충분."
  type        = map(string)
  default = {
    a = "10.0.32.0/24"
    c = "10.0.33.0/24"
  }
}

variable "private_db_subnet_cidrs" {
  description = "Private DB Subnet. RDS 만. Single-AZ 지만 RDS 서브넷 그룹이 AZ 2개를 요구한다."
  type        = map(string)
  default = {
    a = "10.0.40.0/24"
    c = "10.0.41.0/24"
  }
}
