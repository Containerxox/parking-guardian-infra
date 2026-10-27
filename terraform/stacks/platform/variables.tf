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
