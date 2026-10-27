# ---------------------------------------------------------------------------
# AWS Load Balancer Controller: Ingress(config 리포 ingress.yaml)를 보고 ALB·리스너·타깃 그룹을 만드는 컨트롤러.
# 구성 3개: IAM 정책(무엇을 할 수 있나) → Pod Identity 역할·연결(어느 Pod 에게) → Helm 릴리스(컨트롤러 설치)
#
# ServiceAccount 이름 aws-load-balancer-controller(kube-system)는 계약표의 값. Helm 차트가 만들고, Pod Identity 연결이 그 이름을 가리킨다.
# ---------------------------------------------------------------------------

# < IAM 정책 > 컨트롤러 공식 정책 JSON(16개 statement, 80개 action: elasticloadbalancing·ec2·acm·wafv2·shield 등).
# 직접 쓰기엔 너무 길고 버전마다 바뀌므로 공식 파일을 그대로 둔다(계정 ID 없음, 공개 가능).
resource "aws_iam_policy" "alb_controller" {
  name        = "${var.project_name}-alb-controller"
  description = "AWS Load Balancer Controller v${var.alb_controller_chart_version} official policy"
  policy      = file("${path.module}/alb-controller-iam-policy.json")

  tags = {
    Name = "${var.project_name}-alb-controller"
  }
}

# < Pod Identity 역할 > 신뢰 주체 pods.eks.amazonaws.com (cluster 스택의 CloudWatch·backend 역할과 같은 모양).
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.project_name}-alb-controller"
  description        = "Pod Identity role for AWS Load Balancer Controller (kube-system/aws-load-balancer-controller)"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = {
    Name = "${var.project_name}-alb-controller"
  }
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

resource "aws_eks_pod_identity_association" "alb_controller" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.alb_controller.arn

  tags = {
    Name = "${var.project_name}-alb-controller"
  }
}

# < Helm 릴리스 > 차트 eks/aws-load-balancer-controller. 설치 1~2분.
# 컨트롤러가 알아야 하는 것: 클러스터 이름(타깃 그룹 태그), 리전, VPC ID(Subnet·SG 탐색. IMDS 조회 대신 명시해 hop limit 과 무관하게).
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.alb_controller_chart_version

  # helm provider 3.x: set 은 리스트 속성. 값은 모두 문자열.
  set = [
    { name = "clusterName", value = var.cluster_name },
    { name = "region", value = var.aws_region },
    { name = "vpcId", value = var.vpc_id },
    # ServiceAccount 는 차트가 만든다. IRSA 어노테이션은 없다(Pod Identity 는 이름으로 연결).
    { name = "serviceAccount.create", value = "true" },
    { name = "serviceAccount.name", value = "aws-load-balancer-controller" },
    # 설계 4.3 자원 표는 컨트롤러 1개 기준. 기본값 2 는 노드 2대에 CPU 가 빡빡해 1 로.
    { name = "replicaCount", value = "1" },
    # Service 오브젝트에 웹훅으로 어노테이션을 넣는 기능. Ingress 만 쓰므로 끈다(웹훅 하나 줄어 Service 생성이 단순해진다).
    { name = "enableServiceMutatorWebhook", value = "false" },
  ]

  # 컨트롤러 Pod 가 Ready 될 때까지 기다린다. Pod Identity 연결이 먼저 있어야 Pod 가 자격 증명을 받는다.
  wait    = true
  timeout = 600

  depends_on = [aws_eks_pod_identity_association.alb_controller]
}
