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
