# ---------------------------------------------------------------------------
# NAT Gateway (architecture.md 4.2): Private App Subnet 의 노드·Pod 가 인터넷으로 "나가는" 길.
# 들어오는 연결은 받지 않는다(그건 Public Subnet 의 ALB 가 한다).
#
# 노드가 밖으로 나가야 하는 것: ECR API(이미지 매니페스트·인증. 레이어 본체는 S3 Endpoint), EKS API, STS, CloudWatch,
#   Helm 차트·컨테이너 레지스트리(ECR Public, GHCR 등), OS 패키지, 외부 알림 API.
#
# 왜 network 가 아니라 cluster 스택인가: 시간당 약 $0.059 + 처리 GB 당 $0.059 로 비용이 붙는다.
#   클러스터가 없을 때 NAT 만 켜 둘 이유가 없으므로 클러스터와 같은 수명으로 묶는다(매일 생성·삭제).
# 왜 1개인가: 2개(AZ 마다)면 비용이 2배. AZ a 장애 시 AZ c 노드의 외부 통신이 끊기는 것을 감수한다(설계).
#   NAT 는 AZ a Public Subnet 에 두고, 두 AZ 의 Private App Subnet 이 같은 라우트 테이블로 여기로 온다.
# ---------------------------------------------------------------------------

# < Elastic IP > NAT 의 고정 공인 IP. NAT 는 EIP 가 필수다.
# 이 IP 가 "노드·Pod 가 밖에 보일 때의 주소" 다. 외부 서비스 IP 허용 목록에 넣을 값은 이것.
# EIP 는 NAT 에 붙어 있는 동안 무료, 떼어 놓고 안 쓰면 시간당 $0.005.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat"
  }
}

# < NAT Gateway > Public Subnet a 에 놓는다. 생성 1~2분.
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = var.public_subnet_ids[0] # AZ a (network 출력은 키 "a","c" 순)

  tags = {
    Name = "${var.project_name}-nat-a"
  }

  # Public Subnet 의 IGW 경로가 있어야 NAT 가 밖으로 나갈 수 있다. network 스택이 이미 만들었으므로 명시적 의존은 없다.
}

# < Private App 라우트 테이블에 기본 경로 추가 > 0.0.0.0/0 → NAT.
# 이 라우트 테이블은 network 스택 소유다. network 가 route 를 inline 블록으로 쓰지 않았기 때문에
# 다른 스택인 여기서 aws_route 하나를 추가해도 network 의 다음 plan 이 "모르는 경로" 라며 지우지 않는다.
# destroy 하면 이 경로만 사라지고 Private App Subnet 은 다시 "인터넷 경로 없음" 으로 돌아간다(S3 Endpoint 경로는 그대로).
resource "aws_route" "private_app_nat" {
  route_table_id         = var.private_app_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}
