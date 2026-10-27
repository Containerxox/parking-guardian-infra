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

variable "state_noncurrent_version_days" {
  description = "State 객체의 이전 버전을 보관하는 일수. 지나면 삭제해 버전 누적 비용을 막는다. 현재 버전은 영향 없음."
  type        = number
  default     = 90
}
