# ---------------------------------------------------------------------------
# KEDA operator 의 Pod Identity 역할 (Phase 2, ADR 0019, config 리포 docs/phase2.md P3)
#
# 하는 일: config 리포의 ScaledObject(worker)가 SQS 판별 큐의 대기 수를 15초마다 읽는다. 그 호출을 하는 것은 Worker 가 아니라
#   KEDA operator Pod 다(namespace keda, ServiceAccount keda-operator). 그래서 이 역할은 operator 에 붙는다.
#   TriggerAuthentication 이 `podIdentity.provider: aws` 에 roleArn 을 적지 않으므로 KEDA 는 operator 자신의 기본 자격 증명 체인을 쓴다
#   (KEDA 소스 aws_config_cache.go: UsingPodIdentity 이고 AwsRoleArn 이 비면 LoadDefaultConfig 의 자격 증명을 유지). EKS Pod Identity 는
#   Pod 에 AWS_CONTAINER_CREDENTIALS_FULL_URI 를 주입하고 Go SDK 의 기본 체인이 이를 읽는다. AWS 규범 가이드의 방식과 같다.
#   (가이드는 operator 역할 → 앱 역할 AssumeRole 2단 구성을 보여 주지만, 우리는 조회 권한 하나뿐이라 역할 하나로 충분하다.)
#
# 권한 (최소): sqs:GetQueueAttributes, 본 큐 하나. 근거 = KEDA aws_sqs_queue_scaler.go 가 하는 AWS 호출은 GetQueueAttributes 하나뿐이고
#   (ApproximateNumberOfMessages, ApproximateNumberOfMessagesNotVisible), queueURL 을 그대로 쓰므로 GetQueueUrl 이 필요 없다. FIFO 특수 처리 없음.
#   SQS 암호화는 SSE-SQS(키 관리 없음)라 KMS 권한도 필요 없다. DLQ·S3·Secrets 권한 없음. 큐 정책(HTTPS 전용 Deny)과 충돌하지 않는다.
#
# 이름 계약: Namespace keda, ServiceAccount keda-operator 는 KEDA 차트의 기본값(serviceAccount.operator.name)이고 config 리포
#   platform/keda/values.yaml 이 명시해 둔다. 바꾸려면 양쪽을 같이 고친다. Namespace 는 Argo CD 앱 keda 가 만든다(CreateNamespace).
#
# 순서: Pod Identity 는 Pod 가 만들어질 때 자격 증명 설정을 주입한다. 이 연결이 KEDA operator Pod 보다 먼저 있어야 한다.
#   cluster 스택 apply 가 Argo CD(platform 스택)와 keda 앱보다 먼저이므로 정상 재구축 순서에서는 지켜진다.
#   KEDA 를 먼저 띄웠다면 `kubectl -n keda rollout restart deploy keda-operator`.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "keda_operator" {
  statement {
    sid       = "QueueDepth"
    effect    = "Allow"
    actions   = ["sqs:GetQueueAttributes"]
    resources = [var.judgement_queue_arn]
  }
}

resource "aws_iam_role" "keda_operator" {
  name               = "${var.project_name}-keda-operator"
  description        = "Pod Identity role for the KEDA operator (SA ${var.keda_namespace}/${var.keda_service_account}): read the judgement queue depth only"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = {
    Name = "${var.project_name}-keda-operator"
  }
}

resource "aws_iam_role_policy" "keda_operator" {
  name   = "sqs-queue-depth"
  role   = aws_iam_role.keda_operator.name
  policy = data.aws_iam_policy_document.keda_operator.json
}

resource "aws_eks_pod_identity_association" "keda_operator" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.keda_namespace
  service_account = var.keda_service_account
  role_arn        = aws_iam_role.keda_operator.arn

  tags = {
    Name = "${var.project_name}-keda-operator"
  }

  depends_on = [aws_eks_addon.pod_identity_agent]
}
