# ---------------------------------------------------------------------------
# External Secrets Operator(ESO): Secrets Manager 의 비밀을 읽어 Kubernetes Secret 으로 만들어 주는 컨트롤러.
# config 리포의 ClusterSecretStore(platform/) 와 ExternalSecret backend-secrets(apps/) 가 이것을 전제한다.
# 구성 3개: IAM 정책(비밀 3개 읽기만) → Pod Identity 역할·연결(external-secrets/external-secrets) → Helm 릴리스
#
# 설치 뒤 Pod 3개(controller, webhook, cert-controller. 설계 자원 표의 "ESO ×3"). AWS 를 호출하는 것은 controller 만이지만
# 셋이 같은 ServiceAccount 를 쓰므로 연결은 하나다.
# ---------------------------------------------------------------------------

# < IAM 정책 > 비밀 3개의 값 읽기와 메타데이터 조회만. 쓰기·삭제·목록 없음. 다른 비밀은 ARN 이 없으니 못 읽는다.
# KMS 권한은 필요 없다: 세 비밀 모두 AWS 관리형 키(aws/secretsmanager)라 Secrets Manager 가 대신 복호화한다.
data "aws_iam_policy_document" "eso" {
  statement {
    sid    = "ReadAppSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      var.app_secret_arn,
      var.seed_secret_arn,
      var.rds_secret_arn,
    ]
  }
}

resource "aws_iam_role" "eso" {
  name               = "${var.project_name}-eso"
  description        = "Pod Identity role for External Secrets Operator (external-secrets/external-secrets): read 3 secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json # alb_controller.tf 의 공용 신뢰 정책

  tags = {
    Name = "${var.project_name}-eso"
  }
}

resource "aws_iam_role_policy" "eso" {
  name   = "secrets-read"
  role   = aws_iam_role.eso.name
  policy = data.aws_iam_policy_document.eso.json
}

# Namespace·ServiceAccount 이름은 차트 기본값(external-secrets / external-secrets). 계약표의 값.
resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = var.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn

  tags = {
    Name = "${var.project_name}-eso"
  }
}

# < Helm 릴리스 > 차트 external-secrets/external-secrets. CRD(ClusterSecretStore, ExternalSecret 등)도 함께 설치한다.
# 이 CRD 가 있어야 config 리포의 kubectl apply -f platform/ 이 된다(결정 17 의 순서 조건).
resource "helm_release" "eso" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.eso_chart_version

  set = [
    # CRD 설치. 차트를 지우면 CRD 도 지워지고 ExternalSecret·ClusterSecretStore 오브젝트가 함께 사라진다(이 스택 destroy 전에 config 리포를 먼저 지우는 이유).
    { name = "installCRDs", value = "true" },
    # ServiceAccount 는 차트가 만든다. 어노테이션 없음(Pod Identity).
    { name = "serviceAccount.create", value = "true" },
    { name = "serviceAccount.name", value = "external-secrets" },
    # 앱 하나·비밀 1개라 컨트롤러 1개. 기본값도 1 이지만 명시.
    { name = "replicaCount", value = "1" },
  ]

  wait    = true
  timeout = 600

  depends_on = [aws_eks_pod_identity_association.eso]
}
