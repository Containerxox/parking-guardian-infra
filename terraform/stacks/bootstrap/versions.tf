# bootstrap 스택: 다른 스택이 쓸 Terraform State 버킷을 만든다 (architecture.md 6.1, 6.4 1단계).
# 이 스택만 로컬 State 를 쓴다 (terraform.tfstate 는 .gitignore). 닭과 달걀 문제를 피하기 위해서다.

terraform {
  # use_lockfile(S3 네이티브 잠금, DynamoDB 불필요)은 1.10 부터.
  required_version = ">= 1.10, < 2.0" # Terraform 1.10 이상이고 Terraform 2.0 미만

  required_providers {
    aws = {
      source  = "hashicorp/aws" # HarshiCorp에서 제공하는 AWS Provider를 사용
      version = "~> 6.0"        # AWS Provider의 버전을 6.0 이상, 7.0 미만으로 제한
    }
  }
}
