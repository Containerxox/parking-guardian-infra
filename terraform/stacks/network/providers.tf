# bootstrap 과 동일. 자격 증명·프로필은 코드에 없고 AWS_PROFILE 환경변수로 고른다 (architecture.md 결정 22).
# 실행 전 `aws sts get-caller-identity` 로 계정·사용자를 확인한다 (README "인증").
provider "aws" {
  region = var.aws_region

  # 공통 태그 (architecture.md 4.1). 이 스택의 모든 리소스에 자동으로 붙는다.
  # 리소스마다 Name 태그만 따로 적는다. 환경 태그는 없다(단일 환경).
  default_tags {
    tags = {
      Project   = var.project_name
      Phase     = "1"
      ManagedBy = "terraform"
    }
  }
}
