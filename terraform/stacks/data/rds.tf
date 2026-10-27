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

# < 2) 파라미터 그룹 > PostgreSQL 서버 설정. RDS 기본 그룹(default.postgres16)은 수정할 수 없어서 따로 만든다.
# family 는 엔진 메이저 버전에 묶인다. PostgreSQL 17 로 올리면 postgres17 그룹을 새로 만들어 바꿔 붙인다.
resource "aws_db_parameter_group" "this" {
  name        = "${var.project_name}-postgres16"
  family      = "postgres16"
  description = "PostgreSQL 16 for Parking Guardian: force SSL"

  # SSL 강제. 평문 접속은 거부된다. 앱은 DB_SSLMODE=require (config.py 기본값).
  # RDS 의 PostgreSQL 15+ 는 기본값이 이미 1 이지만, 의도를 코드에 남기기 위해 명시한다.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
    # 이 파라미터는 정적(static)이라 RDS 가 "재시작 때 적용" 으로 기록한다. 기본값 immediate 로 두면 매 plan 에 드리프트가 보인다.
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${var.project_name}-postgres16"
  }
}

# < 3) DB 인스턴스 > 생성 5~10분. 이 리소스부터 시간당 비용이 붙는다(db.t4g.micro 약 $0.025/h + 저장소).
# 유휴 시 `aws rds stop-db-instance --db-instance-identifier parking-guardian` (최대 7일 뒤 자동 재시작).
resource "aws_db_instance" "this" {
  identifier = var.project_name # 엔드포인트 호스트 이름에 들어간다: parking-guardian.xxxx.ap-northeast-2.rds.amazonaws.com

  # --- 엔진 ---
  engine = "postgres"
  # 메이저 버전만 적는다. 마이너는 RDS 기본값(지금 16.13)으로 시작하고 auto_minor_version_upgrade 가 유지 창에서 올린다.
  # "16.13" 처럼 고정하면 자동 업그레이드 뒤 코드와 실제가 달라져 plan 이 바뀐다.
  engine_version             = "16"
  auto_minor_version_upgrade = true
  parameter_group_name       = aws_db_parameter_group.this.name

  # --- 크기 ---
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage_gb
  storage_type      = "gp3" # gp3 20 GB 는 3000 IOPS·125 MB/s 기본 포함
  storage_encrypted = true  # AWS 관리형 키 aws/rds. 만든 뒤 바꿀 수 없다.

  # --- 배치 (network 스택) ---
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_security_group_id] # node SG 에서 5432 만
  publicly_accessible    = false                       # 공인 IP 없음. Private DB Subnet 은 라우트도 local 만
  multi_az               = false                       # Single-AZ (설계. 비교 실습에 집중)

  # --- 데이터베이스와 자격 증명 ---
  db_name  = var.db_name
  username = var.db_master_username
  # RDS 가 비밀번호를 만들어 Secrets Manager 에 저장·회전(기본 7일)한다. Terraform State 에는 비밀의 ARN 만 남는다.
  # password 인수를 쓰지 않으므로 코드·State·Git 어디에도 평문이 없다 (architecture.md 4.8).
  # ESO 가 이 비밀의 username/password 키를 읽어 DB_USER/DB_PASSWORD 로 넘긴다.
  manage_master_user_password = true

  # --- 백업·보호 ---
  backup_retention_period = var.db_backup_retention_days # Free 플랜 상한 1일 (variables.tf)
  backup_window           = "18:00-19:00"                # UTC = 한국 03:00~04:00
  maintenance_window      = "Sun:19:00-Sun:20:00"
  copy_tags_to_snapshot   = true
  deletion_protection     = var.db_deletion_protection

  # destroy 때 최종 스냅샷을 남긴다. 같은 이름의 스냅샷이 이미 있으면 destroy 가 실패하므로, 다시 지우기 전에 옛 스냅샷을 삭제하거나 이름을 바꾼다.
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project_name}-final"

  # --- 변경 적용 시점 ---
  # false(기본): 인스턴스 클래스 변경 등 재시작이 필요한 변경을 다음 유지 창까지 미룬다. 실습 중 즉시 반영이 필요하면 CLI --apply-immediately.
  apply_immediately = false

  tags = {
    Name = var.project_name
  }
}
