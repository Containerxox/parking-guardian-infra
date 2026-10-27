# ---------------------------------------------------------------------------
# VPC: 이 프로젝트의 모든 네트워크 리소스(Subnet, 라우트, SG, EKS, RDS)가 들어가는 격리된 사설 네트워크.
# 리전(ap-northeast-2) 단위 리소스다. AZ 는 그 아래 Subnet 을 만들 때 정한다.
# VPC 자체는 무료다.
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  # IPv4 범위. 만든 뒤에는 바꿀 수 없다(바꾸면 VPC 를 다시 만든다 → 안의 모든 것이 날아간다).
  cidr_block = var.vpc_cidr

  # < DNS 두 옵션 > EKS 가 둘 다 true 를 요구한다. RDS 엔드포인트 주소(xxx.rds.amazonaws.com) 해석,
  # 뒤에 만들 S3 Gateway Endpoint 도 VPC 안 DNS 해석에 의존한다.
  # - enable_dns_support:   VPC 안에서 AWS 제공 DNS 서버(VPC CIDR 의 .2 번 주소)를 쓸 수 있게 한다. 기본값 true.
  # - enable_dns_hostnames: VPC 안 인스턴스(EKS 노드 포함)에 퍼블릭/프라이빗 DNS 이름을 붙여 준다. 기본값 false 라 명시한다.
  enable_dns_support   = true
  enable_dns_hostnames = true

  # 기본값(default) 테넌시. dedicated 는 전용 하드웨어라 비용이 크다.
  instance_tenancy = "default"

  # Project / Phase / ManagedBy 는 provider default_tags 가 붙인다. 여기선 Name 만.
  tags = {
    Name = "${var.project_name}-vpc"
  }
}
