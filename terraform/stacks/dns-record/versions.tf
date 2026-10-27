# dns-record 스택: parking.<도메인> → ALB 의 Route 53 Alias 레코드 하나 (architecture.md 결정 20, 6.4 8단계).
#
# 별도 스택인 이유: ALB 는 Terraform 이 아니라 config 리포의 Ingress(ALB Controller)가 만든다. 최초 구축 때 ALB 가 없는 시점에
#   data 스택에 이 레코드가 있었다면 data 가 apply 되지 않았을 것이다. 그래서 "ALB 가 생긴 뒤" 따로 apply 하는 스택으로 분리했다.
# 값은 tfvars 가 아니라 조회다: data "aws_lb" 가 이름 parking-guardian 으로 ALB 의 DNS 이름·영역 ID 를, data "aws_route53_zone" 이 도메인으로 영역을 찾는다.
# 삭제 순서: ALB 가 사라지면 data "aws_lb" 조회가 실패해 plan 이 깨지므로, 전체 삭제 때 이 스택을 **가장 먼저** destroy 한다.

terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    key = "dns-record/terraform.tfstate"
  }
}
