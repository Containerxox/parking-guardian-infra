# 다른 스택과 동일. 자격 증명·프로필은 코드에 없고 AWS_PROFILE 환경변수로 고른다 (architecture.md 결정 22).
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      Phase     = "1"
      ManagedBy = "terraform"
    }
  }
}
