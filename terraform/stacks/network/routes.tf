# ---------------------------------------------------------------------------
# 라우팅: Subnet 이 "Public" 인지 "Private" 인지는 여기서 정해진다.
#
# 지금 VPC 안에는 AWS 가 자동으로 만든 "기본(main) 라우트 테이블" 하나가 있고,
# 안에는 local 경로(10.0.0.0/16 → VPC 내부) 하나만 있다. 어느 라우트 테이블에도 명시적으로
# 연결되지 않은 Subnet 은 이 main 테이블을 따른다. 즉 지금 Subnet 6개는 전부 "인터넷 경로 없음" 상태다.
#
# 여기서 만드는 것:
#   Internet Gateway 1개         VPC 가 인터넷과 통하는 문. VPC 에 하나만 붙는다. 무료.
#   Public 라우트 테이블 1개      0.0.0.0/0 → IGW.  Public Subnet a, c 연결
#   Private App 라우트 테이블 1개  local 만. (0.0.0.0/0 → NAT 경로는 cluster 스택이 추가한다)
#   Private DB 라우트 테이블 1개   local 만. RDS 는 밖으로 나갈 일이 없다.
#
# App 과 DB 테이블을 나눈 이유: cluster 스택이 NAT 경로를 App 테이블에만 넣는다. DB Subnet 은 영원히 인터넷 경로가 없다.
# AZ 별로 나누지 않은 이유: NAT 가 1개(AZ a)라 두 AZ 가 같은 경로를 쓴다(architecture.md 4.2).
#
# route 를 inline 블록이 아니라 별도 aws_route 리소스로 쓰는 이유:
#   aws_route_table 안에 route {} 블록을 하나라도 적으면 Terraform 이 그 테이블의 "모든" 경로를 관리한다.
#   그러면 cluster 스택이 밖에서 추가한 NAT 경로를 network 스택의 다음 plan 이 "내가 모르는 경로" 라며 지워 버린다.
#   route 블록을 전혀 쓰지 않으면 Terraform 은 경로를 건드리지 않고, 경로는 aws_route 로 하나씩 관리한다.
# ---------------------------------------------------------------------------

# < Internet Gateway >
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# < Public 라우트 테이블 > 경로는 아래 aws_route.public_internet 에서.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-public"
  }
}

# 0.0.0.0/0(모든 목적지) → IGW. local 경로(10.0.0.0/16)는 AWS 가 자동으로 넣어 주므로 적지 않는다.
# 더 구체적인 경로가 우선하므로(longest prefix match) VPC 내부 통신은 여전히 local 로 간다.
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

# Public Subnet a, c 를 Public 테이블에 연결. 이 순간부터 이 Subnet 들이 "Public" 이 된다.
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# < Private App 라우트 테이블 > 지금은 local 만. NAT 경로(0.0.0.0/0 → NAT)는 cluster 스택의 aws_route 가 추가한다.
# S3 Gateway Endpoint 경로는 다음 단계(endpoints.tf)에서 이 테이블에 붙는다.
resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-private-app"
  }
}

resource "aws_route_table_association" "private_app" {
  for_each = aws_subnet.private_app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_app.id
}

# < Private DB 라우트 테이블 > local 만. 인터넷 경로를 영원히 두지 않는다.
resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-private-db"
  }
}

resource "aws_route_table_association" "private_db" {
  for_each = aws_subnet.private_db

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_db.id
}
