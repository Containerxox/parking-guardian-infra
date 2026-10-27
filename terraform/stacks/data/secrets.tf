# ---------------------------------------------------------------------------
# Secrets Manager 빈 컨테이너 2개 (architecture.md 4.8)
#   parking-guardian/app   SECRET_KEY, JWT_SECRET             (Flask 세션·JWT 서명)
#   parking-guardian/seed  SEED_ADMIN_PASSWORD, SEED_DEVICE_KEY_SECRET (데모 관리자 비밀번호, 장비 키 유도 비밀)
#
# 원칙: 비밀 "값" 은 Terraform 코드·State·Git 어디에도 없다. 여기서는 이름(컨테이너)만 만든다.
#   값은 apply 뒤 CLI 로 1회 넣는다(README): aws secretsmanager put-secret-value --secret-id ... --secret-string file://...
#   aws_secretsmanager_secret_version 과 random_password 는 쓰지 않는다. 둘 다 State 에 평문이 남는다.
#   RDS 마스터 비밀번호는 RDS 가 스스로 만들어 관리하므로(rds 단계) 여기 없다.
#
# 소비자: External Secrets Operator(platform 스택의 Pod Identity 역할이 이 비밀들의 ARN 에 Get/Describe)가
#   읽어서 Kubernetes Secret backend-secrets 를 만든다. 매니페스트(config 리포)에는 비밀 "이름" 과 키 이름만 적힌다.
#
# 비용: 비밀 1개당 월 $0.40 + API 1만 건당 $0.05. 2개면 월 $0.80. (Free Tier 는 첫 30일만 무료)
# ---------------------------------------------------------------------------
locals {
  secrets = {
    app = {
      description = "Backend app secrets. JSON keys: SECRET_KEY, JWT_SECRET. Values injected by CLI, not Terraform."
    }
    seed = {
      description = "Backend seed secrets. JSON keys: SEED_ADMIN_PASSWORD, SEED_DEVICE_KEY_SECRET. Values injected by CLI, not Terraform."
    }
  }
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.secrets

  # 이름의 "/" 는 ECR 과 같은 관례. ESO 의 ExternalSecret 이 이 이름으로 조회한다.
  name        = "${var.project_name}/${each.key}"
  description = each.value.description

  # 삭제 유예 기간(일). 삭제하면 이 기간 동안 "삭제 예정" 상태로 남아 복구할 수 있고, 같은 이름을 다시 만들 수 없다.
  # 기본값 30일은 destroy → apply 반복 실습에 걸림돌이라 최소값 7일로 줄인다.
  # 0 으로 하면 즉시 삭제되지만 복구가 불가능하다. 즉시 지워야 하면 CLI:
  #   aws secretsmanager delete-secret --secret-id <이름> --force-delete-without-recovery
  recovery_window_in_days = var.secret_recovery_window_days

  # 암호화 키를 적지 않으면 AWS 관리형 키 aws/secretsmanager 를 쓴다(무료). 고객 관리형 KMS 키는 쓰지 않는다 (결정 23).

  tags = {
    Name = "${var.project_name}/${each.key}"
  }
}
