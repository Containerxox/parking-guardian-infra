# ---------------------------------------------------------------------------
# Phase 2 Pod Identity 역할 (ADR 0019, PHASE2_HANDOFF 5절 3번): api / worker / relay 가 서로 다른 ServiceAccount·역할.
# api 는 기존 backend 역할(iam.tf)에 권한을 더했고, worker 와 relay 는 여기서 새로 만든다. 삭제 권한은 SQS 메시지 외에 없다.
# 권한 근거는 앱 코드가 실제로 부르는 호출이다(adapters/queue.py, adapters/storage.py, services/*).
#
#   api     (기존 backend)  SQS SendMessage(본 큐) / S3 inbox/* Put·Get / violations/* Put·Get / 버킷 ListBucket
#   worker                  SQS Receive·Delete·ChangeVisibility(본 큐) / S3 inbox/* Get, violations/* Put·Get
#                           + 모델 버킷 v*/ List·Get (Worker 가 YOLO 를 직접 돌리므로 inference 와 같은 읽기 권한)
#   relay                   SQS SendMessage(본 큐), Receive·Delete·ChangeVisibility(DLQ), GetQueueAttributes(본 큐·DLQ, 관측성)
#                           + S3 inbox/* Get, violations/* Put·Get (끊긴 부수 효과 = 증거 사진 복사를 마무리한다)
#
# s3:ListBucket 을 주는 이유: S3 는 호출자에게 ListBucket 이 없으면 "없는 객체"를 404(NoSuchKey)가 아니라 403(AccessDenied)으로 답한다.
#   앱은 NoSuchKey 를 FileNotFoundError 로 바꿔 Worker 가 "inbox 사진 없음 → rejected"(영구 오류)로 처리하는데,
#   403 이면 일시 오류로 보고 retry → 3번 뒤 DLQ 로 가 버린다. s3:prefix 조건은 GetObject 요청에는 없는 키라 조건을 달면 권한이 안 먹는다.
#   이 버킷에는 inbox/ 와 violations/ 만 있으므로 키 이름 노출 위험은 낮다.
# ---------------------------------------------------------------------------

locals {
  s3_inbox_objects      = "${var.photos_bucket_arn}/inbox/*"
  s3_violations_objects = "${var.photos_bucket_arn}/violations/*"
}

# --- worker ---------------------------------------------------------------
data "aws_iam_policy_document" "worker" {
  statement {
    sid    = "JudgementQueueConsume"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [var.judgement_queue_arn]
  }

  statement {
    sid       = "InboxRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.s3_inbox_objects]
  }

  # 부수 효과: 확정 증거 사진을 violations/ 로 저장하고 결과를 확인(HeadObject 는 GetObject 권한).
  statement {
    sid       = "EvidenceWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = [local.s3_violations_objects]
  }

  statement {
    sid       = "PhotosListForNotFound"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.photos_bucket_arn]
  }

  # 모델 읽기: inference 역할(iam.tf)과 같은 범위.
  statement {
    sid       = "ModelsList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.models_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["v*/*", "v*"]
    }
  }

  statement {
    sid       = "ModelsGet"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.models_bucket_arn}/v*/*"]
  }
}

resource "aws_iam_role" "worker" {
  name               = "${var.project_name}-worker"
  description        = "Pod Identity role for worker (SA ${var.app_namespace}/${var.worker_service_account}): consume judgement queue, read inbox, write evidence, read models"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = {
    Name = "${var.project_name}-worker"
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "judgement-worker"
  role   = aws_iam_role.worker.name
  policy = data.aws_iam_policy_document.worker.json
}

resource "aws_eks_pod_identity_association" "worker" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.app_namespace
  service_account = var.worker_service_account
  role_arn        = aws_iam_role.worker.arn

  tags = {
    Name = "${var.project_name}-worker"
  }

  depends_on = [aws_eks_addon.pod_identity_agent]
}

# --- relay ----------------------------------------------------------------
data "aws_iam_policy_document" "relay" {
  statement {
    sid       = "JudgementQueueSend"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [var.judgement_queue_arn]
  }

  # DLQ 를 읽어 DB 의 dead_lettered 로 옮기고 지운다. 읽을 수 없는 메시지는 ChangeMessageVisibility 로 1시간 숨기기만 한다.
  statement {
    sid    = "DlqDrain"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [var.judgement_dlq_arn]
  }

  # 관측성 2단계 (2026-11-06): Relay 가 15초마다 두 큐의 대략적인 메시지 수(대기·처리 중·지연)를 읽어 Prometheus 지표로 낸다. 읽기 전용 속성 조회 1개, 본 큐와 DLQ 만.
  # 이 권한이 없으면 큐 깊이 지표가 나오지 않고(0 이 아니라 "없음") 알림 PGPipelineMetricsMissing 이 울린다. 판정·발행 동작에는 영향이 없다.
  statement {
    sid       = "QueueDepthRead"
    effect    = "Allow"
    actions   = ["sqs:GetQueueAttributes"]
    resources = [var.judgement_queue_arn, var.judgement_dlq_arn]
  }

  statement {
    sid       = "InboxRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.s3_inbox_objects]
  }

  statement {
    sid       = "EvidenceWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = [local.s3_violations_objects]
  }

  statement {
    sid       = "PhotosListForNotFound"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.photos_bucket_arn]
  }
}

resource "aws_iam_role" "relay" {
  name               = "${var.project_name}-relay"
  description        = "Pod Identity role for relay (SA ${var.app_namespace}/${var.relay_service_account}): publish to judgement queue, drain DLQ, finish side effects"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = {
    Name = "${var.project_name}-relay"
  }
}

resource "aws_iam_role_policy" "relay" {
  name   = "judgement-relay"
  role   = aws_iam_role.relay.name
  policy = data.aws_iam_policy_document.relay.json
}

resource "aws_eks_pod_identity_association" "relay" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.app_namespace
  service_account = var.relay_service_account
  role_arn        = aws_iam_role.relay.arn

  tags = {
    Name = "${var.project_name}-relay"
  }

  depends_on = [aws_eks_addon.pod_identity_agent]
}
