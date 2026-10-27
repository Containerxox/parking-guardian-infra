# ---------------------------------------------------------------------------
# RDS PostgreSQL 16 (architecture.md 4.5). 세 조각으로 나눠 만든다:
#   1) DB 서브넷 그룹   어느 Subnet 에 둘 수 있는가           ← 이 파일의 첫 리소스
#   2) 파라미터 그룹    PostgreSQL 설정(SSL 강제 등)
#   3) DB 인스턴스      db.t4g.micro, Single-AZ, gp3 20 GB, 관리형 비밀번호
#
# RDS 는 EKS 와 달리 Subnet 을 직접 받지 않고 "서브넷 그룹" 이라는 묶음을 받는다.
# Single-AZ 인스턴스도 그룹에는 AZ 2개 이상이 있어야 한다(장애 시 다른 AZ 로 옮기거나 Multi-AZ 로 바꿀 여지를 두는 요건).
# 인스턴스는 그룹 안의 Subnet 중 하나(AZ 하나)에 실제로 놓인다.
# ---------------------------------------------------------------------------

# < 1) DB 서브넷 그룹 > Private DB Subnet a, c (network 스택). 이 Subnet 들은 라우트가 local 만 있어 인터넷과 단절되어 있다.
resource "aws_db_subnet_group" "this" {
  name        = "${var.project_name}-db"
  description = "Private DB subnets (AZ a, c) for RDS PostgreSQL"
  subnet_ids  = var.private_db_subnet_ids

  tags = {
    Name = "${var.project_name}-db"
  }
}
