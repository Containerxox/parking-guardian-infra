# cluster 스택: 비용이 큰 것. 쓸 때 apply, 끝나면 destroy (architecture.md 6.1, 6.4).
#   nat(NAT Gateway) → eks(클러스터) → nodes(관리형 노드 그룹) → addons(관리형 Add-on) → iam(Pod Identity) → observability(CloudWatch)
# network·data 스택은 유지되고, 이 스택만 매일 생성·삭제한다. 그래서 network 의 라우트 테이블에 NAT 경로를 "밖에서" 추가한다.
# 입력은 network 출력(Subnet·라우트 테이블·SG·VPC ID)과 data 출력(버킷 ARN)을 terraform.tfvars 로 받는다.

terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    key = "cluster/terraform.tfstate"
  }
}
