# network 스택: VPC, Subnet, 라우트, S3 Gateway Endpoint, SG (architecture.md 4.2, 6.1).
# 수명이 길고 비용 0 인 것만 둔다. 비용이 드는 NAT Gateway 는 매일 지우는 cluster 스택 소속이다.

terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # < State 저장 위치 > bootstrap 이 만든 S3 버킷.
  # bucket / region / encrypt / use_lockfile 은 모든 스택이 같으므로 코드에 적지 않고
  # init 때 파일로 받는다:  terraform init -backend-config=../../backend.hcl
  # (backend.hcl 에는 계정 ID 가 들어가서 gitignore 대상. 코드에는 계정 ID 를 두지 않는다.)
  # key 만 스택마다 다르다. 버킷 안 경로 <스택>/terraform.tfstate.
  # backend 블록은 변수(var.*)를 쓸 수 없다. init 단계는 변수 평가 전에 실행되기 때문이다.
  backend "s3" {
    key = "network/terraform.tfstate"
  }
}
