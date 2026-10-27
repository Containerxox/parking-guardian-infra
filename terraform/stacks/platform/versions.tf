# platform 스택: 클러스터 "안" 에 들어가는 공용 컨트롤러 (architecture.md 6.1, 결정 16).
#   AWS Load Balancer Controller(Ingress → ALB), External Secrets Operator(Secrets Manager → Secret) 를 Helm 으로 설치하고,
#   둘의 IAM 역할을 Pod Identity 로 연결한다. 앱 매니페스트(config 리포)는 이 둘이 있어야 동작한다.
#
# cluster 스택과 나눈 이유: helm provider 는 설정 시점에 "이미 있는" 클러스터의 엔드포인트·CA 가 필요하다.
#   EKS 생성과 같은 apply 에 두면 첫 실행에서 provider 설정값이 비어 꼬인다(설계 6.1). 그래서 cluster 가 끝난 뒤 이 스택을 apply 한다.
# 수명은 cluster 와 같다(매일 생성·삭제). 지울 때는 config 리포의 Ingress → 이 스택 → cluster 순서(ALB 고아 방지).

terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0" # 3.x 는 kubernetes 설정이 블록이 아니라 "속성(= {...})" 문법이다
    }
  }

  backend "s3" {
    key = "platform/terraform.tfstate"
  }
}
