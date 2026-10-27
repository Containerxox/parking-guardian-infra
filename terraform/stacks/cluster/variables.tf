variable "aws_region" {
  description = "리전. 장비와 관리자가 모두 한국이므로 서울."
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "리소스 이름과 Project 태그의 접두어."
  type        = string
  default     = "parking-guardian"
}

# ---------------------------------------------------------------------------
# network 스택에서 받는 값 (architecture.md 6.4 표: cluster ← network). terraform.tfvars 에 적는다.
#   terraform -chdir=../network output -json public_subnet_ids
#   terraform -chdir=../network output -raw  private_app_route_table_id
# ---------------------------------------------------------------------------
variable "public_subnet_ids" {
  description = "network 출력 public_subnet_ids (AZ a, c 순). NAT Gateway 는 첫 번째(AZ a)에 둔다. EKS 클러스터 Subnet 에도 들어간다."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 1
    error_message = "public_subnet_ids 가 비어 있다."
  }
}

variable "private_app_route_table_id" {
  description = "network 출력 private_app_route_table_id. 여기에 0.0.0.0/0 → NAT 경로를 추가한다."
  type        = string
}

variable "private_app_subnet_ids" {
  description = "network 출력 private_app_subnet_ids. EKS 컨트롤 플레인 ENI 와 노드가 놓이는 Subnet(AZ a, c)."
  type        = list(string)

  validation {
    condition     = length(var.private_app_subnet_ids) >= 2
    error_message = "EKS 는 AZ 가 다른 Subnet 2개 이상이 필요하다."
  }
}

# ---------------------------------------------------------------------------
# EKS 클러스터 (architecture.md 4.3)
# ---------------------------------------------------------------------------
variable "eks_version" {
  description = <<-EOT
    Kubernetes 버전. 표준 지원 기간 안의 버전만(확장 지원은 시간당 6배). 2026-10-27 기준 표준 지원 1.34~1.37.
    1.35 를 고른 이유: 관리형 Add-on 6개가 모두 지원되고, 이 PC 의 kubectl 1.34 와 마이너 1 차이(허용 범위), 표준 지원 2027-03 까지.
  EOT
  type        = string
  default     = "1.35"
}

variable "eks_public_access_cidrs" {
  description = "API 서버 퍼블릭 엔드포인트에 접근할 수 있는 CIDR. 보통 관리자 PC 의 공인 IP/32. 기본값 없음(tfvars). IP 가 바뀌면 여기만 고치고 apply."
  type        = list(string)

  validation {
    condition     = length(var.eks_public_access_cidrs) > 0 && !contains(var.eks_public_access_cidrs, "0.0.0.0/0")
    error_message = "eks_public_access_cidrs 는 비울 수 없고 0.0.0.0/0 은 허용하지 않는다(API 서버가 인터넷에 열린다)."
  }
}

variable "eks_cluster_log_types" {
  description = "CloudWatch 로 보낼 컨트롤 플레인 로그. api, audit, authenticator, controllerManager, scheduler. 비우면 끔(기본. audit 는 하루 수백 MB 가 될 수 있어 비용). 디버깅 때 [\"api\", \"authenticator\"] 정도."
  type        = list(string)
  default     = []
}

variable "node_security_group_id" {
  description = "network 출력 node_security_group_id. 노드에 '추가' 로 붙는 SG(alb 에서 5000·8080 수신, 아웃바운드 전체). 클러스터 SG 는 EKS 가 따로 붙인다."
  type        = string
}

# ---------------------------------------------------------------------------
# 노드 그룹 (architecture.md 4.3)
# ---------------------------------------------------------------------------
variable "node_instance_type" {
  description = <<-EOT
    노드 인스턴스. 설계 4.3 은 m7i.large(2 vCPU, 8 GiB) 였으나 AWS Free 플랜은 Free Tier 적격 타입만 띄울 수 있다
    (2026-10-27 Auto Scaling 실패: "The specified instance type is not eligible for Free Tier").
    서울 리전 적격 x86 타입 중 8 GiB 는 m7i-flex.large 하나다(같은 m7i 세대, 2 vCPU, 8 GiB, 최대 Pod 29개).
    flex 는 평균 사용률 40% 를 전제한 타입이라 추론이 CPU 를 오래 꽉 채우면 m7i.large 보다 느릴 수 있다. 측정 기록에 이 점을 적는다.
    유료 플랜으로 바꾸면 m7i.large 로 되돌린다(노드 그룹 재생성).
  EOT
  type        = string
  default     = "m7i-flex.large"
}

variable "node_disk_gb" {
  description = "노드 루트 볼륨(gp3) 크기. Backend 이미지 2.9 GB + 캐시 레이어 + 로그. 설계 50 GB."
  type        = number
  default     = 50
}

variable "node_desired_size" {
  description = "노드 수. 2 = AZ 분산 + Rolling 배포(새 backend 1000m 이 같은 노드엔 못 뜸)."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "최소 노드 수. 0 이면 desired 를 0 으로 내려 노드 비용만 끌 수 있다(클러스터는 유지)."
  type        = number
  default     = 0
}

variable "node_max_size" {
  description = "최대 노드 수. 측정 때 3대째를 '새 노드(이미지 캐시 없음)' 로 쓴다."
  type        = number
  default     = 3
}

# ---------------------------------------------------------------------------
# 관리형 Add-on / CloudWatch (architecture.md 4.10)
# ---------------------------------------------------------------------------
variable "log_retention_days" {
  description = "Container Insights 로그 그룹(application, dataplane, host, performance)의 보관 일수. 설계 7일."
  type        = number
  default     = 7
}
