# ---------------------------------------------------------------------------
# Phase 2 판별 큐 (ADR 0019, 설계 6.3 / 6.7 / 6.12): SQS FIFO 2개
#
#   judgement      본 큐. 접수 API(와 Relay)가 보내고 Worker 가 받는다.
#                  MessageGroupId = 장비 → 같은 장비의 메시지는 순서대로, 다른 장비끼리는 병렬.
#                  MessageDeduplicationId = 작업(job) ID. 내용 기반 중복 제거는 끈다(앱이 ID 를 직접 정한다).
#   judgement-dlq  데드 레터 큐. 본 큐에서 3번 받고도 못 지운 메시지가 자동으로 온다.
#
# 로컬 ElasticMQ(docker/elasticmq/elasticmq.conf)와 같은 값을 쓴다. 에뮬레이터가 적용하지 않던 것
# (DLQ 보존 4일, 중복 제거 5분 창, FIFO 의 DLQ 이동 방식)은 실제 AWS 에서 확인한다(PHASE2_HANDOFF 5절 1번).
#
# 값의 근거
#   visibility_timeout 60초   Worker 의 리스(lease) 55초보다 길어야 한다. 리스가 먼저 끝나고 메시지가 다시 보이는 순서가 맞다.
#                             리스는 연장하지 않는다(알려진 위험). 첫 모델 로딩 약 34초는 warm_up 으로 흡수되는지 AWS 에서 확인한다.
#   maxReceiveCount 3         3번 받아도 지워지지 않으면 DLQ. Relay 가 DLQ 를 읽어 DB 의 dead_lettered 로 옮긴다.
#   보존 4일 (본 큐·DLQ)       ADR 0019 결정 10. FIFO 큐는 DLQ 로 옮겨질 때 보존 시계가 다시 시작된다(공식 문서) → AWS 에서 확인 항목.
#                             본 큐 메시지가 4일 안에 소비되지 못하면 조용히 사라진다. DB 가 진실의 원천이고 Relay 가 pending_publish 를
#                             다시 보내므로 유실은 아니지만, Worker 가 4일 이상 멈추는 상황은 경보로 잡아야 한다(CloudWatch 는 별도 단계).
#   SSE-SQS                   SQS 가 관리하는 암호화(키 관리 없음). 결정 23(KMS 미사용)과 같은 이유.
# ---------------------------------------------------------------------------

locals {
  judgement_queue_name = "${var.project_name}-judgement.fifo"
  judgement_dlq_name   = "${var.project_name}-judgement-dlq.fifo"
  sqs_retention_secs   = var.judgement_retention_days * 24 * 60 * 60
}

resource "aws_sqs_queue" "judgement_dlq" {
  name       = local.judgement_dlq_name
  fifo_queue = true

  content_based_deduplication = false
  visibility_timeout_seconds  = 30
  message_retention_seconds   = local.sqs_retention_secs
  sqs_managed_sse_enabled     = true

  tags = {
    Name = local.judgement_dlq_name
  }
}

resource "aws_sqs_queue" "judgement" {
  name       = local.judgement_queue_name
  fifo_queue = true

  content_based_deduplication = false
  visibility_timeout_seconds  = var.judgement_visibility_timeout_seconds
  message_retention_seconds   = local.sqs_retention_secs
  sqs_managed_sse_enabled     = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.judgement_dlq.arn
    maxReceiveCount     = var.judgement_max_receive_count
  })

  tags = {
    Name = local.judgement_queue_name
  }
}

# < DLQ 가 받을 수 있는 원본 큐 > 본 큐 하나만 허용한다. 다른 큐가 이 DLQ 를 실수로 쓰지 못하게 한다.
resource "aws_sqs_queue_redrive_allow_policy" "judgement_dlq" {
  queue_url = aws_sqs_queue.judgement_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.judgement.arn]
  })
}

# < HTTPS 전용 > S3 버킷 정책과 같은 원칙. boto3 는 기본이 HTTPS 라 정상 호출은 영향이 없다.
data "aws_iam_policy_document" "sqs_deny_insecure" {
  for_each = {
    judgement     = aws_sqs_queue.judgement.arn
    judgement_dlq = aws_sqs_queue.judgement_dlq.arn
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [each.value]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "judgement" {
  queue_url = aws_sqs_queue.judgement.id
  policy    = data.aws_iam_policy_document.sqs_deny_insecure["judgement"].json
}

resource "aws_sqs_queue_policy" "judgement_dlq" {
  queue_url = aws_sqs_queue.judgement_dlq.id
  policy    = data.aws_iam_policy_document.sqs_deny_insecure["judgement_dlq"].json
}

# --- 출력: config 리포(SQS_QUEUE_URL, SQS_DLQ_URL)와 cluster 스택(IAM)이 받는다 ---
output "judgement_queue_url" {
  description = "판별 큐 URL. config 리포 config.env 의 SQS_QUEUE_URL."
  value       = aws_sqs_queue.judgement.url
}

output "judgement_dlq_url" {
  description = "판별 DLQ URL. config 리포 config.env 의 SQS_DLQ_URL."
  value       = aws_sqs_queue.judgement_dlq.url
}

output "judgement_queue_arn" {
  description = "cluster 스택 api/worker/relay Pod Identity 정책의 본 큐 ARN."
  value       = aws_sqs_queue.judgement.arn
}

output "judgement_dlq_arn" {
  description = "cluster 스택 relay Pod Identity 정책의 DLQ ARN."
  value       = aws_sqs_queue.judgement_dlq.arn
}
