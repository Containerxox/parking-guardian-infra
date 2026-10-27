# ---------------------------------------------------------------------------
# Subnet: VPC 를 AZ 별·역할별로 잘라 낸 조각. Subnet 은 AZ 하나에만 속한다.
# "Public / Private" 는 Subnet 자체 속성이 아니다. 다음 단계에서 어떤 라우트 테이블을 붙이느냐로 정해진다
# (0.0.0.0/0 → Internet Gateway 가 있으면 Public, NAT 로 가거나 없으면 Private).
# 그래서 여기서는 3계층을 "역할" 로 나누고, 라우트는 routes.tf 에서 붙인다. Subnet 은 무료다.
#
# 역할별 3종 × AZ 2개(a, c) = 6개.
#   public      : ALB, NAT Gateway
#   private_app : EKS 노드·Pod
#   private_db  : RDS
# ---------------------------------------------------------------------------

# < Public Subnet ×2 >
resource "aws_subnet" "public" {
  # for_each 는 map 을 돌면서 키마다 리소스 하나를 만든다.
  # each.key = "a" | "c", each.value = CIDR. 주소는 aws_subnet.public["a"] 처럼 된다.
  for_each = var.public_subnet_cidrs

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = "${var.aws_region}${each.key}" # ap-northeast-2a / ap-northeast-2c

  # 이 Subnet 에 뜨는 ENI 에 공인 IP 를 자동으로 붙인다. ALB·NAT 는 자기 IP 를 따로 받으므로 필수는 아니지만
  # "여기는 Public" 이라는 관례적 표시. Private Subnet 은 기본값 false 로 둔다.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${each.key}"
    # AWS Load Balancer Controller 가 인터넷용 ALB 를 둘 Subnet 을 이 태그로 자동 찾는다.
    # 값은 "1" 문자열. 없으면 Ingress 에 subnets 어노테이션을 직접 적어야 한다.
    "kubernetes.io/role/elb" = "1"
  }
}

# < Private App Subnet ×2 > EKS 노드와 Pod
resource "aws_subnet" "private_app" {
  for_each = var.private_app_subnet_cidrs

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = "${var.aws_region}${each.key}"

  tags = {
    Name = "${var.project_name}-private-app-${each.key}"
    # 내부용(internal) 로드밸런서를 둘 Subnet 표시. Phase 1 에선 internal LB 가 없지만 설계값대로 붙여 둔다.
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# < Private DB Subnet ×2 > RDS 전용. Kubernetes 태그 없음(노드·LB 가 들어오지 않게).
resource "aws_subnet" "private_db" {
  for_each = var.private_db_subnet_cidrs

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = "${var.aws_region}${each.key}"

  tags = {
    Name = "${var.project_name}-private-db-${each.key}"
  }
}
