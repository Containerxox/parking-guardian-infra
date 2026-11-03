# ---------------------------------------------------------------------------
# S3 버킷 2개 (architecture.md 4.6, 4.7)
#   photos  위반 사진. Backend 의 S3ImageStorage 가 violations/<company>/<lot>/<날짜>/... 키로 put/get/head.
#           읽기는 Backend 경유라 버킷은 완전 비공개. Lifecycle 없음(EXPIRED 처리와 함께 뒤에).
#   models  YOLO 모델. v1/default.pt(42 MB), v1/last.pt(370 MB). initContainer 가 Pod 시작마다 v1/ 을 sync.
#           객체는 Terraform 이 올리지 않는다(Git 에 없음). apply 뒤 `aws s3 sync` 1회(README).
#
# 두 버킷의 보안 설정은 bootstrap 의 State 버킷과 같다: 소유권 강제(ACL 끔), 퍼블릭 차단, SSE-S3, HTTPS 전용.
# 같은 설정을 두 번 적지 않기 위해 for_each 로 묶는다. 리소스 주소는 aws_s3_bucket.this["photos"] 처럼 된다.
#
# 버전 관리는 켜지 않는다. 사진은 덮어쓰지 않고(키에 violation_id 포함), 모델은 v1/ v2/ 접두어로 버전을 나누기 때문이다.
# 켜면 노이즈 버전이 쌓여 비용만 든다.
# ---------------------------------------------------------------------------

# 버킷 이름은 전역 유일해야 하므로 계정 ID 를 붙인다. 계정 ID 는 코드에 없고 실행 신원에서 읽는다 (bootstrap 과 동일).
data "aws_caller_identity" "current" {}

locals {
  buckets = {
    photos = "${var.project_name}-photos-${data.aws_caller_identity.current.account_id}"
    models = "${var.project_name}-models-${data.aws_caller_identity.current.account_id}"
  }
}

# < 버킷 > force_destroy 기본값 false: 객체가 남아 있으면 destroy 가 실패한다. 사진 버킷의 실수 삭제를 막는 안전장치.
resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket = each.value

  tags = {
    Name = each.value
  }
}

# < ACL 비활성 > 버킷 소유자가 모든 객체를 소유. Pod 가 올린 객체도 계정 소유.
resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# < 퍼블릭 차단 > 4개 전부 켠다. 사진 URL 이 밖으로 새어도 열리지 않는다.
resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# < 기본 암호화 > SSE-S3(AES-256). KMS 고객 관리형 키는 쓰지 않는다 (결정 23, Free Plan).
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# < HTTPS 전용 > 평문 HTTP 요청은 모두 거부. (boto3 와 aws s3 sync 는 기본이 HTTPS)
data "aws_iam_policy_document" "deny_insecure" {
  for_each = aws_s3_bucket.this

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      each.value.arn,
      "${each.value.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  policy = data.aws_iam_policy_document.deny_insecure[each.key].json

  # 퍼블릭 차단이 먼저 적용된 뒤 정책을 붙인다.
  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ---------------------------------------------------------------------------
# Phase 2: 사진 버킷 inbox/ 수명 주기 (ADR 0019 결정 10)
#   inbox/m-<장비>/<event_id> = 판별용 임시 사진. 확정 증거는 Worker/Relay 가 violations/ 로 복사해 두므로
#   inbox 는 7일 뒤 지워도 된다. violations/ 에는 규칙을 걸지 않는다(90일 만료는 앱의 EXPIRED 처리와 함께 뒤에).
#   만료된 inbox 사진을 가리키는 중복 요청은 앱이 비교 없이 200 으로 처리한다(ingest.py).
#   주의: 앱의 S3_PREFIX 를 설정하면 실제 키가 바뀐다. 지금은 비워 둔다(config 리포 확인).
#   버전 관리를 켜지 않은 버킷이라 만료 = 영구 삭제.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "photos" {
  bucket = aws_s3_bucket.this["photos"].id

  # < 보존 기간 순서 검증 > 본 큐 보존 < inbox 보존. 반대로 되면 메시지가 사진보다 오래 살아서 Worker 가
  #   rejected(missing_image) 를 만들고, Relay 의 멈춘 작업 복구(앱 RELAY_STALLED_AFTER_SECONDS, 기본 1일)가
  #   복구하려는 사진도 이미 없다. 변수 validation 은 다른 변수를 참조하지 못하는 버전이 있어 여기서 plan 단계에 막는다.
  #   (DLQ 는 이동 시점부터 보존 시계가 다시 시작되므로 접수 후 최대 약 2배까지 살 수 있다. 그 구간은
  #   ADR 0019 "10단계 AWS 인프라 사전 검토"에 위험으로 기록돼 있고 이 검증이 막지는 않는다.)
  lifecycle {
    precondition {
      condition     = var.inbox_retention_days > var.judgement_retention_days
      error_message = "inbox_retention_days (${var.inbox_retention_days}) must be greater than judgement_retention_days (${var.judgement_retention_days}): a queue message must not outlive the inbox photo it points to."
    }
  }

  rule {
    id     = "expire-inbox"
    status = "Enabled"

    filter {
      prefix = "inbox/"
    }

    expiration {
      days = var.inbox_retention_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
