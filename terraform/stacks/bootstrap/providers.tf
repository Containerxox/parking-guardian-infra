# 자격 증명과 프로필은 적지 않는다. AWS CLI 와 같은 기본 체인을 쓰고, 프로필은 AWS_PROFILE 환경변수로 고른다 (architecture.md 결정 22).
# 실행 전 `aws sts get-caller-identity` 로 계정·사용자를 확인한다 (README "인증").
provider "aws" {
  region = var.aws_region

  # 공통 태그 (architecture.md 4.1). 환경 태그는 없다(단일 환경).
  default_tags {
    tags = {
      Project   = var.project_name
      Phase     = "1"
      ManagedBy = "terraform"
    }
  }
}
