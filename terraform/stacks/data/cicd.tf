# ---------------------------------------------------------------------------
# GitHub Actions 가 ECR 에 이미지를 푸시할 때 쓰는 AWS 인증. 장기 Access Key 를 GitHub Secrets 에 두지 않는다.
#
# 동작:
#   1) 워크플로가 GitHub 의 OIDC 공급자(token.actions.githubusercontent.com)에서 짧은 수명의 JWT 를 받는다.
#      JWT 안에 "어느 리포, 어느 브랜치에서 돌고 있는가"(sub 클레임)가 적혀 있다.
#   2) 그 JWT 로 AWS STS 에 AssumeRoleWithWebIdentity 를 호출해 아래 역할의 임시 자격 증명(1시간)을 받는다.
#   3) AWS 는 신뢰 정책의 조건(aud, sub)으로 "우리 리포의 develop/main 에서 온 토큰인가" 를 확인한다.
# 그래서 GitHub 쪽에 저장하는 값은 비밀이 아닌 역할 ARN 하나뿐이다.
#
# 구성 3개: OIDC 공급자(계정에 1개) → IAM 역할(신뢰 정책 = 누가 맡을 수 있나) → IAM 정책(권한 = 무엇을 할 수 있나)
# 모두 IAM 이라 비용 0. 글로벌 리소스.
# ---------------------------------------------------------------------------

# < OIDC 공급자 > "GitHub 가 발행한 토큰을 이 계정이 신뢰한다" 는 등록. 계정당 URL 하나만 만들 수 있다.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # 토큰의 aud(대상) 클레임. aws-actions/configure-aws-credentials 가 이 값으로 토큰을 요청한다.
  client_id_list = ["sts.amazonaws.com"]

  # GitHub 인증서 체인의 지문. AWS 는 GitHub OIDC 에 대해 자체 신뢰 루트로 검증하므로 지금은 값이 쓰이지 않지만 API 가 필드를 요구한다.
  # GitHub 문서가 안내하는 두 값을 둔다.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = {
    Name = "github-actions"
  }
}

# < 신뢰 정책 > 이 역할을 "누가" 맡을 수 있나. 리포와 브랜치를 sub 클레임으로 제한한다.
#   sub 형식: repo:<owner>/<repo>:ref:refs/heads/<branch>
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    sid     = "GitHubOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for b in var.github_branches : "repo:${var.github_repository}:ref:refs/heads/${b}"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = "${var.project_name}-github-actions"
  description          = "Assumed by GitHub Actions (${var.github_repository}) via OIDC to push images to ECR"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_trust.json
  max_session_duration = 3600 # 1시간. 빌드 하나에 충분

  tags = {
    Name = "${var.project_name}-github-actions"
  }
}

# < 권한 정책 > "무엇을" 할 수 있나. ECR 푸시에 필요한 최소 동작만, 대상은 우리 리포지토리 2개만.
data "aws_iam_policy_document" "github_actions_ecr" {
  # 로그인 토큰 발급은 리소스 단위로 제한할 수 없어 "*" 가 필수.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # 레이어 업로드 + 매니페스트 등록(푸시) + 이미 있는 태그인지 확인(불변 태그 중복 빌드 방지).
  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]
    resources = [for r in aws_ecr_repository.this : r.arn]
  }
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name   = "ecr-push"
  role   = aws_iam_role.github_actions.name
  policy = data.aws_iam_policy_document.github_actions_ecr.json
}
