# 계정 ID 는 코드에 적지 않고 실행 신원에서 읽는다 (architecture.md 6.3: 계정 ID 는 tfvars·State 밖의 파일에 두지 않음).
# < 현재 AWS 계정 ID 조회 >
# data "조회할 데이터 종류" "Terraform 내부 이름"
# - data: 기존 정보를 조회하는 블록
# - aws_caller_identity: 현재 AWS 실행 신원 조회
# - current: Terraform 내부에서 붙인 이름
data "aws_caller_identity" "current" {}

# < S3 버킷 이름 생성 >
locals {
  # 버킷 이름은 전역 유일해야 하므로 다른 버킷(photos, models)과 같은 규칙으로 계정 ID 를 붙인다.
  state_bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
}

# KMS 고객 관리형 키는 쓰지 않는다 (결정 23, 2026-10-26): AWS Free Plan 유지. State 암호화는 아래 SSE-S3.

# ---------------------------------------------------------------------------
# S3: State 버킷. 스택 6개가 같은 버킷을 key 만 다르게 쓴다 (<스택>/terraform.tfstate).
# < State 저장할 S3 버킷 생성 >
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  # force_destroy 기본값 false: 객체가 남아 있으면 destroy 가 실패한다 (6.4절 "State 버킷은 비운 뒤").
  lifecycle {
    prevent_destroy = true
  }
}

# < ACL 비활성화 > 버킷 소유자가 모든 객체를 소유한다.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# < 퍼블릭 접근 차단 > = Terraform State 버킷이 실수로 인터넷에 공개되는 것을 방지함
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# < 버전 관리 >: 잘못된 apply 뒤 이전 State 로 되돌릴 수 있게.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# < 기본 암호화 > SSE-S3(AES-256). S3 가 관리하는 키라 추가 비용과 KMS 권한이 없다.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# < 이전 버전 정리 >. 버전 관리가 켜진 뒤에 만들어야 하므로 depends_on.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.state_noncurrent_version_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

# HTTPS 가 아닌 접근은 모두 거부.
data "aws_iam_policy_document" "state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  # 퍼블릭 액세스 차단이 먼저 적용된 뒤 정책을 붙인다.
  depends_on = [aws_s3_bucket_public_access_block.state]
}
