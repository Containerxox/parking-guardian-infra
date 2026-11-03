# ---------------------------------------------------------------------------
# ALB 액세스 로그 버킷 (Phase 1 ALB 502 원인 분석용, 2026-11-01)
#
# 요청 경로와 클라이언트 IP 가 들어가므로 완전 비공개다. 기존 버킷(storage_s3.tf)과 같은 보안 설정에 더해
#   - 7일 뒤 객체 만료(Lifecycle): 분석이 끝나면 저절로 지워지고 비용이 쌓이지 않는다.
#   - ELB 로그 전달 서비스(logdelivery.elasticloadbalancing.amazonaws.com)에게만 alb/AWSLogs/<계정>/* 쓰기 허용.
#     AWS 공식 문서의 현재 권장 방식이다(지역별 ELB 계정 ID 를 쓰는 방식은 레거시). aws:SourceArn 으로
#     이 계정·리전의 로드밸런서만 쓸 수 있게 막는다.
#   - 암호화는 SSE-S3 만 지원된다(ALB 로그는 KMS 불가).
#
# 기존 for_each 버킷에 합치지 않고 따로 둔다: 기존 리소스 주소를 건드리지 않아 plan 에 기존 리소스 변경이 생기지 않는다.
# ALB 쪽 설정(access_logs.s3.*)은 config 리포의 Ingress 어노테이션이 담당한다(ALB 는 Load Balancer Controller 가 만든다).
#
# 삭제 순서 주의: 이 버킷을 지우기 전에 반드시 ALB 의 액세스 로그를 먼저 끈다(공식 문서 경고: 같은 이름의 남의 버킷으로
# 로그가 갈 수 있다). 해체 순서에 "Ingress 의 access_logs 제거 또는 dns/Ingress 삭제 → 버킷 삭제"가 들어간다.
# ---------------------------------------------------------------------------

locals {
  alb_logs_bucket = "${var.project_name}-alb-logs-${data.aws_caller_identity.current.account_id}"
  alb_logs_prefix = "alb"
}

resource "aws_s3_bucket" "alb_logs" {
  bucket = local.alb_logs_bucket

  tags = {
    Name = local.alb_logs_bucket
  }
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-after-7-days"
    status = "Enabled"

    filter {}

    expiration {
      days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.alb_logs.arn,
      "${aws_s3_bucket.alb_logs.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowElbLogDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    actions = ["s3:PutObject"]

    # 계정 ID 를 경로에 넣어 이 계정의 로드밸런서만 쓰게 한다(와일드카드 금지: 공식 보안 권장).
    resources = [
      "${aws_s3_bucket.alb_logs.arn}/${local.alb_logs_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
    ]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:elasticloadbalancing:${var.aws_region}:${data.aws_caller_identity.current.account_id}:loadbalancer/*"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json

  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

output "alb_logs_bucket_name" {
  description = "ALB 액세스 로그 버킷 이름. config 리포 Ingress 의 access_logs.s3.bucket (prefix 는 alb)."
  value       = aws_s3_bucket.alb_logs.bucket
}
