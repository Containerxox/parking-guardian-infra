variable "aws_region" {
  description = "리전."
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "리소스 이름 접두어. ALB 이름도 이 값(config 리포 ingress.yaml 의 load-balancer-name 과 계약)."
  type        = string
  default     = "parking-guardian"
}

variable "domain_name" {
  description = "Route 53 Hosted Zone 이름(data 스택 domain_name 과 같은 값). terraform.tfvars 에만."
  type        = string
}

variable "app_hostname" {
  description = "레코드 이름의 앞부분. data 스택 app_hostname 과 같은 값(ACM 인증서 이름과 일치해야 한다)."
  type        = string
  default     = "parking"
}
