# ---------------------------------------------------------------------------
# backend Pod Identity (architecture.md 4.6, 4.8): backend Pod 가 S3 두 버킷에 접근하는 권한.
#
# 동작: Pod 의 AWS SDK(boto3, aws cli) → 노드의 Pod Identity Agent → "이 Pod 의 ServiceAccount 에 연결된 역할" 의 임시 자격 증명.
#   연결(association) = (클러스터, Namespace, ServiceAccount 이름) ↔ IAM 역할. ServiceAccount 에 어노테이션이 필요 없고(IRSA 와 차이),
#   역할 신뢰 정책에 클러스터별 OIDC 공급자도 필요 없다(addons.tf 의 pod_identity_trust 와 같은 신뢰 정책을 모든 Pod Identity 역할이 공유).
#
# config 리포 쪽: Namespace parking-guardian, ServiceAccount backend (계약표). 이름이 다르면 자격 증명이 안 나와 initContainer 가
#   "Unable to locate credentials" 로 실패한다.
#
# 권한 범위(설계 4.6 "삭제 없음"):
#   사진 버킷  violations/* 에 Put/Get/Head.  삭제 없음. 버킷 루트의 다른 접두어도 없음
#   모델 버킷  v*/ 접두어의 List/Get.           initContainer 의 aws s3 sync 가 ListBucket + GetObject 를 쓴다
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "backend" {
  # 사진 저장·조회. HeadObject 는 GetObject 권한으로 허용된다(별도 action 없음).
  statement {
    sid    = "PhotosReadWrite"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
    ]
    resources = ["${var.photos_bucket_arn}/violations/*"]
  }

  # 모델 다운로드. ListBucket 은 버킷 ARN 에, prefix 조건으로 v*/ 만 보이게.
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

resource "aws_iam_role" "backend" {
  name               = "${var.project_name}-backend"
  description        = "Pod Identity role for backend (SA ${var.app_namespace}/${var.backend_service_account}): photos put/get, models get/list"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json # addons.tf 의 공용 신뢰 정책

  tags = {
    Name = "${var.project_name}-backend"
  }
}

resource "aws_iam_role_policy" "backend_s3" {
  name   = "s3-photos-models"
  role   = aws_iam_role.backend.name
  policy = data.aws_iam_policy_document.backend.json
}

# < 연결 > Namespace·ServiceAccount 는 아직 클러스터에 없어도 된다(이름만 등록). config 리포가 뒤에 만들면 그때부터 동작.
resource "aws_eks_pod_identity_association" "backend" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.app_namespace
  service_account = var.backend_service_account
  role_arn        = aws_iam_role.backend.arn

  tags = {
    Name = "${var.project_name}-backend"
  }

  depends_on = [aws_eks_addon.pod_identity_agent]
}
