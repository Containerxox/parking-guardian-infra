# data 스택: 수명이 긴 데이터·계정 자원 (architecture.md 6.1).
#   budget(Budgets) → dns(Route 53 영역, ACM) → storage(S3 ×2, ECR ×2)
#   → secrets(Secrets Manager 빈 컨테이너) → rds. 이 순서로 하나씩 추가한다.
# cluster 스택을 매일 지워도 이 스택은 유지한다. 비용은 RDS(정지 가능)와 Route 53 영역($0.5/월) 정도.
# network 스택의 출력(VPC ID, DB Subnet ID, rds SG ID)을 terraform.tfvars 로 받는다(RDS 단계에서).

terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # bucket/region/encrypt/use_lockfile 은 ../../backend.hcl 로 주입. key 만 여기 고정.
  backend "s3" {
    key = "data/terraform.tfstate"
  }
}
