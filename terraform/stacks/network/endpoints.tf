# ---------------------------------------------------------------------------
# VPC Endpoint: VPC 안에서 AWS 서비스로 가는 트래픽이 인터넷(IGW·NAT)을 거치지 않고 AWS 망 안에서 끝나게 한다.
#
# 종류 2가지 (architecture.md 4.2):
#   Gateway   : S3, DynamoDB 만 지원. 라우트 테이블에 "S3 IP 대역(prefix list) → 이 Endpoint" 경로를 넣는 방식. 무료.
#   Interface : 나머지 서비스(ECR API, STS, CloudWatch 등). Subnet 에 ENI 를 만든다. 개당 월 $7 + 데이터 요금.
#               → 안 쓴다. 그 서비스들은 NAT 로 나간다.
#
# S3 Gateway Endpoint 를 두는 이유:
#   Private App Subnet 의 노드가 쓰는 S3 트래픽이 크다.
#     - ECR 이미지 레이어 (Backend 2.89 GB. ECR 레이어 본체는 S3 에 있다)
#     - 모델 파일 (default.pt, last.pt 412 MB, initContainer 가 Pod 시작마다 받음)
#     - 위반 사진 업로드
#   이것이 NAT 를 거치면 NAT 데이터 요금($0.059/GB)이 붙고 느리다. Endpoint 로 가면 무료이고 AWS 망 안이다.
#
# 라우트 테이블에 붙이는 방식이라 "어느 Subnet 이 쓰는가" 는 route_table_ids 로 정해진다.
#   private_app  O  노드·Pod 가 S3 를 쓴다
#   private_db   X  RDS 는 S3 를 쓸 일이 없다. DB 테이블은 local 만 둔다(routes.tf 원칙)
#   public       X  ALB·NAT 는 S3 를 쓰지 않는다. (NAT 자체가 S3 로 가는 건 노드 트래픽인데, 그건 이미 Endpoint 로 빠진다)
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  vpc_endpoint_type = "Gateway"

  # 서비스 이름은 리전마다 다르다. com.amazonaws.<리전>.s3
  service_name = "com.amazonaws.${var.aws_region}.s3"

  # 이 테이블들에 AWS 가 경로를 자동으로 추가한다: "pl-xxxx(S3 prefix list) → vpce-xxxx".
  # routes.tf 에서 route 를 inline 으로 쓰지 않았기 때문에 Terraform 이 이 자동 경로를 지우려 하지 않는다.
  route_table_ids = [aws_route_table.private_app.id]

  # policy 를 적지 않으면 "모든 주체가 모든 S3 작업 가능" 기본 정책이다. Endpoint 정책은 S3 버킷 정책·IAM 과 AND 로 걸리므로
  # 실제 권한은 Pod Identity 의 IAM 정책(cluster 스택)이 좁힌다.
  # 여기서 버킷을 제한하지 않는 이유: ECR 레이어가 AWS 소유 버킷(prod-<리전>-starport-layer-bucket)에 있어서
  # 우리 버킷만 허용하면 이미지 Pull 이 깨진다. Phase 1 은 기본 정책으로 둔다.

  tags = {
    Name = "${var.project_name}-s3-endpoint"
  }
}
