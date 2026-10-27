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
# Budgets (architecture.md 4.1, 결정 12)
# ---------------------------------------------------------------------------
variable "monthly_budget_usd" {
  description = "월 예산(USD). 설계 5절의 '하루 4시간 × 30일 + data 유지 ≈ $80' 에 여유를 둔 값."
  type        = number
  default     = 100
}

variable "budget_alert_thresholds" {
  description = "경보를 보낼 실제 누적 비용(USD 절대값). 예산 대비 % 가 아니다. 각 값마다 알림 1개가 생긴다."
  type        = list(number)
  default     = [50, 100]
}

variable "budget_alert_emails" {
  description = "경보를 받을 이메일. 개인 정보라 기본값이 없고 terraform.tfvars(gitignore)에만 적는다."
  type        = list(string)

  validation {
    condition     = length(var.budget_alert_emails) > 0
    error_message = "budget_alert_emails 에 최소 1개 이메일이 필요하다 (terraform.tfvars 에 적는다)."
  }
}

# ---------------------------------------------------------------------------
# ECR (architecture.md 4.7)
# ---------------------------------------------------------------------------
variable "ecr_keep_images" {
  description = "리포지토리마다 유지할 태그 있는 이미지 수. 넘으면 오래된 것부터 Lifecycle 정책이 지운다."
  type        = number
  default     = 10
}

# ---------------------------------------------------------------------------
# Secrets Manager (architecture.md 4.8)
# ---------------------------------------------------------------------------
variable "secret_recovery_window_days" {
  description = "비밀 삭제 뒤 복구 가능 기간(일). 7~30, 또는 0(즉시 삭제, 복구 불가). 실습 반복을 위해 최소값."
  type        = number
  default     = 7

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days 는 0 또는 7~30 이어야 한다."
  }
}

# ---------------------------------------------------------------------------
# network 스택에서 받는 값 (architecture.md 6.4 표: data ← network).
# 기본값이 없다. terraform.tfvars 에 적는다(ID 는 Git 에 올리지 않음). 값은 network 스택의 terraform output 에서:
#   terraform -chdir=../network output -json private_db_subnet_ids
#   terraform -chdir=../network output -raw  rds_security_group_id
# terraform_remote_state 로 직접 읽지 않는 이유: data 스택이 network 의 State 버킷 읽기 권한에 묶이고,
# 어느 값을 받는지가 코드에 드러나지 않는다. 변수로 받으면 입력이 명시적이고 스택 사이 결합이 느슨하다.
# ---------------------------------------------------------------------------
variable "private_db_subnet_ids" {
  description = "network 출력 private_db_subnet_ids. RDS 서브넷 그룹. AZ 가 다른 Subnet 2개 이상."
  type        = list(string)

  validation {
    condition     = length(var.private_db_subnet_ids) >= 2
    error_message = "RDS 서브넷 그룹은 AZ 가 다른 Subnet 이 2개 이상 필요하다."
  }
}

variable "rds_security_group_id" {
  description = "network 출력 rds_security_group_id. RDS 인스턴스에 붙는 SG(node 에서 5432 만 허용)."
  type        = string
}

# ---------------------------------------------------------------------------
# RDS 인스턴스 (architecture.md 4.5)
# ---------------------------------------------------------------------------
variable "db_instance_class" {
  description = "인스턴스 클래스. t4g = Graviton(ARM) 버스터블. 부족하면 db.t4g.small."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage_gb" {
  description = "gp3 저장소 크기(GB). gp3 최소 20."
  type        = number
  default     = 20
}

variable "db_name" {
  description = "처음 만들 데이터베이스 이름. 앱 config.py 의 DB_NAME 기본값과 같다."
  type        = string
  default     = "parking_guardian"
}

variable "db_master_username" {
  description = "마스터 사용자 이름. 비밀번호는 RDS 가 만들어 Secrets Manager 에 둔다. 앱 config.py 의 DB_USER 기본값과 같다."
  type        = string
  default     = "parking"
}

variable "db_backup_retention_days" {
  description = <<-EOT
    자동 백업 보관 일수. 0 이면 백업 끔. 설계는 7일이었으나 AWS Free 플랜은 상한이 1일이다
    (CreateDBInstance 가 FreeTierRestrictionError 로 거부, 2026-10-27). 유료 플랜으로 바꾸면 7 로 올린다.
  EOT
  type        = number
  default     = 1
}

variable "db_deletion_protection" {
  description = "true 면 콘솔·CLI·Terraform 어디서도 삭제가 거부된다. 지울 때는 먼저 false 로 apply."
  type        = bool
  default     = true
}
