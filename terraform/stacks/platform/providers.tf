# aws provider 는 다른 스택과 동일(AWS_PROFILE 환경변수).
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

# < 클러스터 접속 정보 > 이름만 tfvars 로 받고 엔드포인트·CA 는 조회한다.
# 설계 6.4 표는 셋 다 tfvars 로 넘기는 것으로 적었지만, CA 는 1,000자 넘는 base64 라 tfvars 에 복사하기 번거롭고 틀리기 쉽다.
# 이름 하나로 조회하면 cluster 가 재생성되어 CA 가 바뀌어도 tfvars 를 고칠 필요가 없다.
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

# < helm provider > Helm 차트를 설치할 클러스터와 인증 방법.
# 인증: 고정 토큰을 State 에 두지 않고, apply 때마다 `aws eks get-token` 을 실행해 15분짜리 토큰을 받는다(exec).
#   이 명령은 AWS_PROFILE 환경변수를 그대로 쓰므로 Terraform 실행자(PG_test)의 신원으로 접속한다.
#   PG_test 는 cluster 스택의 bootstrap_cluster_creator_admin_permissions 로 cluster-admin 이다.
provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region]
    }
  }
}
