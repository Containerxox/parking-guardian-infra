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
