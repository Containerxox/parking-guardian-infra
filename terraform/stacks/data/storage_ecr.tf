# ---------------------------------------------------------------------------
# ECR 리포지토리 2개 (architecture.md 4.7): parking-guardian/backend, parking-guardian/frontend
# 이미지는 PC 에서 빌드·푸시한다(Terraform 은 리포지토리만). 태그는 Git 짧은 해시.
#
# 비용: 저장 $0.10/GB·월. Backend 2.89 GB 이미지 10개면 압축 기준 약 10 GB → 월 $1 안팎.
# 전송: 노드가 이미지를 받을 때 ECR API 는 NAT 를 거치지만, 레이어 본체는 S3 라 network 스택의 S3 Endpoint 로 빠진다.
#
# 리포지토리 이름의 "/" 는 네임스페이스처럼 보이게 하는 관례일 뿐 계층 구조는 아니다.
# ---------------------------------------------------------------------------
locals {
  ecr_repositories = toset(["backend", "frontend"])
}

resource "aws_ecr_repository" "this" {
  # set 을 for_each 하면 each.key == each.value. 주소는 aws_ecr_repository.this["backend"].
  for_each = local.ecr_repositories

  name = "${var.project_name}/${each.key}"

  # IMMUTABLE: 같은 태그로 다시 푸시할 수 없다. "abc1234 태그 = 그 커밋의 이미지" 가 항상 성립해
  # 배포 매니페스트의 태그만 보고 무엇이 떠 있는지 알 수 있다. latest 처럼 움직이는 태그는 못 쓴다.
  image_tag_mutability = "IMMUTABLE"

  # 푸시할 때마다 OS 패키지 취약점을 기본 스캔(무료). 결과는 콘솔·describe-image-scan-findings.
  image_scanning_configuration {
    scan_on_push = true
  }

  # AES256 = SSE-S3 상당의 기본 암호화. KMS 는 쓰지 않는다 (결정 23).
  encryption_configuration {
    encryption_type = "AES256"
  }

  # force_delete 기본값 false: 이미지가 남아 있으면 destroy 가 실패한다. 삭제 전에 비운다(README).

  tags = {
    Name = "${var.project_name}/${each.key}"
  }
}

# < Lifecycle 정책 > 태그 있는 이미지 최근 10개만 유지. 그 이상은 오래된 것부터 삭제해 저장 비용을 막는다.
# 태그 없는(untagged) 이미지는 같은 태그를 다시 푸시할 수 없으므로(IMMUTABLE) 거의 생기지 않지만,
# 멀티 아키텍처 매니페스트의 조각 등으로 생길 수 있어 1일 뒤 삭제 규칙을 둔다.
# 정책은 JSON 이라 jsonencode 로 HCL 에서 만든다(따옴표·쉼표 실수 방지).
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "untagged 이미지는 1일 뒤 삭제"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "태그 있는 이미지 최근 ${var.ecr_keep_images}개 유지"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_keep_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
