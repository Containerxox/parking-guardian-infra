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

# ---------------------------------------------------------------------------
# Security Group (architecture.md 4.2 "SG 사슬")
# ---------------------------------------------------------------------------
variable "alb_ingress_cidrs" {
  description = <<-EOT
    ALB 의 80·443 을 열어 주는 IPv4 CIDR 목록. **기본값이 없다 — 반드시 직접 지정해야 한다.**
    (이전에는 기본값이 ["0.0.0.0/0"](인터넷 전체)였다. terraform.tfvars 를 빠뜨린 PC 에서 apply 하면 ALB 가 전체 공개되는 사고를 막으려고 기본값을 없앴다.)
    평소: 허용할 공인 IP 의 /32 를 terraform.tfvars(gitignore)에 적는다.  alb_ingress_cidrs = ["203.0.113.7/32"]
    전체 공개가 정말 필요하면 ["0.0.0.0/0"] 를 명시해서 적는다(운영 공개 시점의 의도된 선택이어야 한다).
    주의: 제한하면 현장 장비(Raspberry Pi)도 그 IP 가 아니면 접속하지 못한다. 공인 IP 가 바뀌면 이 값을 고쳐 다시 apply 한다(README 의 복구 절차).
    규칙을 먼저 만들고(create_before_destroy) 옛 규칙을 지우므로 값을 바꿔도 접속이 끊기는 틈이 없다.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.alb_ingress_cidrs) > 0
    error_message = "alb_ingress_cidrs 는 비어 있으면 안 된다. 허용할 IPv4 CIDR 을 하나 이상 적는다(예: [\"203.0.113.7/32\"])."
  }

  validation {
    condition     = alltrue([for c in var.alb_ingress_cidrs : can(cidrhost(c, 0)) && !strcontains(c, ":")])
    error_message = "alb_ingress_cidrs 의 모든 값은 IPv4 CIDR(주소/접두어) 이어야 한다. 예: 203.0.113.7/32. IPv6·접두어 없는 주소는 안 된다."
  }

  validation {
    condition     = alltrue([for c in var.alb_ingress_cidrs : !can(cidrhost(c, 0)) || cidrhost(c, 0) == split("/", c)[0]])
    error_message = "alb_ingress_cidrs 의 CIDR 은 네트워크 주소여야 한다(호스트 비트가 0). 예: 203.0.113.0/24 는 되고 203.0.113.7/24 는 안 된다. 단일 IP 는 /32 로 적는다."
  }
}

variable "app_ports" {
  description = "ALB 가 Pod 로 보내는 컨테이너 포트. 키는 규칙 이름, 값은 포트. Backend Flask 5000, Frontend nginx(비특권 이미지) 8080."
  type        = map(number)
  default = {
    backend  = 5000
    frontend = 8080
  }
}
