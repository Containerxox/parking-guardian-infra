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
# cluster 스택에서 받는 값 (architecture.md 6.4 표: platform ← cluster)
#   terraform -chdir=../cluster output -raw cluster_name
# ---------------------------------------------------------------------------
variable "cluster_name" {
  description = "cluster 출력 cluster_name. 엔드포인트·CA 는 이 이름으로 조회한다(providers.tf)."
  type        = string
}

# ---------------------------------------------------------------------------
# network 스택에서 받는 값 (architecture.md 6.4 표: platform ← network)
#   terraform -chdir=../network output -raw vpc_id
# ---------------------------------------------------------------------------
variable "vpc_id" {
  description = "network 출력 vpc_id. ALB Controller 가 Subnet·SG 를 찾을 VPC."
  type        = string
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller (architecture.md 4.4, 4.9)
# ---------------------------------------------------------------------------
variable "alb_controller_chart_version" {
  description = <<-EOT
    Helm 차트 eks/aws-load-balancer-controller 의 버전. 차트 버전 = 컨트롤러(appVersion) 버전과 같다(3.6.2 = v3.6.2).
    옆의 alb-controller-iam-policy.json 은 이 버전의 공식 정책이다. 버전을 올리면 정책 파일도 같은 태그에서 다시 받는다:
      https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v<버전>/docs/install/iam_policy.json
  EOT
  type        = string
  default     = "3.6.2"
}

# ---------------------------------------------------------------------------
# data 스택에서 받는 값 (architecture.md 6.4 표: platform ← data). ESO 가 읽을 비밀 3개의 ARN.
#   terraform -chdir=../data output -json secret_arns      → app, seed
#   terraform -chdir=../data output -raw  db_master_secret_arn
# ---------------------------------------------------------------------------
variable "app_secret_arn" {
  description = "data 출력 secret_arns.app (parking-guardian/app: SECRET_KEY, JWT_SECRET)."
  type        = string
}

variable "seed_secret_arn" {
  description = "data 출력 secret_arns.seed (parking-guardian/seed: SEED_ADMIN_PASSWORD, SEED_DEVICE_KEY_SECRET)."
  type        = string
}

variable "rds_secret_arn" {
  description = "data 출력 db_master_secret_arn (RDS 관리형: username, password)."
  type        = string
}

# ---------------------------------------------------------------------------
# External Secrets Operator (architecture.md 4.8)
# ---------------------------------------------------------------------------
variable "eso_chart_version" {
  description = "Helm 차트 external-secrets/external-secrets 버전(= 앱 버전). config 리포의 ExternalSecret 은 API external-secrets.io/v1 을 쓴다(ESO 1.x 이상)."
  type        = string
  default     = "2.14.0"
}
