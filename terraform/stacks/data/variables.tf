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
