# ---------------------------------------------------------------------------
# 관리형 Add-on 6개 (architecture.md 4.3). EKS 가 설치·업그레이드를 맡는 클러스터 구성요소.
#
#   vpc-cni                  Pod 에 VPC IP 를 주는 네트워크 플러그인(aws-node DaemonSet)
#   coredns                  클러스터 DNS(Service 이름 → ClusterIP)
#   kube-proxy               Service 트래픽을 Pod 로 돌리는 iptables 규칙
#   eks-pod-identity-agent   Pod 가 "자기 ServiceAccount 에 연결된 IAM 역할" 의 자격 증명을 받게 하는 노드 에이전트. iam.tf 의 전제
#   metrics-server           kubectl top, HPA 용 CPU·메모리 지표
#   amazon-cloudwatch-observability  CloudWatch Agent(Container Insights 지표) + Fluent Bit(컨테이너 로그 → CloudWatch Logs)
#
# 앞의 셋은 클러스터를 만들 때 EKS 가 "자체 관리(self-managed)" 상태로 이미 넣어 두었다. aws_eks_addon 으로 만들면 관리형으로
# 전환되는데, 이미 있는 오브젝트와 충돌하므로 resolve_conflicts_on_create = OVERWRITE 가 필요하다.
# 전환 뒤 업데이트는 PRESERVE: 우리가 configuration_values 로 바꾼 설정을 EKS 기본값이 덮어쓰지 않게.
#
# addon_version 을 적지 않으면 클러스터 버전의 기본 버전이 설치되고, 뒤에 기본 버전이 바뀌어도 plan 이 흔들리지 않는다
# (2026-10-27 기본: vpc-cni v1.22.4, coredns v1.13.2, kube-proxy v1.35.3, pod-identity-agent v1.4.1, metrics-server v0.9.0, cloudwatch v6.7.0).
# 올리고 싶을 때 addon_version 을 명시한다. EBS CSI 는 없다(PVC 를 쓰지 않는다. 모델은 emptyDir, 사진은 S3).
# ---------------------------------------------------------------------------

# < 네트워크 3종 > 이미 있는 자체 관리 버전을 관리형으로 전환.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  # 자격 증명은 노드 역할의 AmazonEKS_CNI_Policy (nodes.tf). Pod Identity 로 분리하는 것은 뒤 Phase.
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

# CoreDNS 는 Deployment(2 replica)라 노드가 있어야 Running 이 된다. 노드 그룹 뒤에.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.main]
}

# < Pod Identity Agent > DaemonSet. 노드마다 떠서 Pod 의 AWS SDK 요청을 받아 연결된 역할의 임시 자격 증명을 돌려준다.
# 이것이 있어야 aws_eks_pod_identity_association(iam.tf, 그리고 아래 CloudWatch)이 동작한다.
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.main]
}

# < metrics-server > kubectl top nodes/pods. 측정(2.1절)에서 Pod 의 CPU·메모리를 볼 때.
resource "aws_eks_addon" "metrics_server" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "metrics-server"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.main]
}

# ---------------------------------------------------------------------------
# < CloudWatch Observability > (architecture.md 4.10) Container Insights 지표 + Fluent Bit 로그.
# 에이전트가 CloudWatch 에 쓰려면 IAM 권한이 필요하다. 노드 역할에 정책을 붙이는 옛 방식 대신,
# Add-on 의 pod_identity_association 으로 ServiceAccount cloudwatch-agent(amazon-cloudwatch Namespace)에 역할을 연결한다.
# 이것이 이 스택의 첫 Pod Identity 사용 예다. backend 의 S3 역할(iam.tf)도 같은 모양이다.
# ---------------------------------------------------------------------------

# Pod Identity 역할의 신뢰 정책: 주체는 pods.eks.amazonaws.com, 동작은 AssumeRole + TagSession(둘 다 필요).
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

resource "aws_iam_role" "cloudwatch_agent" {
  name               = "${var.project_name}-cloudwatch-agent"
  description        = "Pod Identity role for the CloudWatch Observability add-on (cloudwatch-agent SA)"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = {
    Name = "${var.project_name}-cloudwatch-agent"
  }
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch_agent.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Fluent Bit 이 쓰는 로그 그룹 4개를 먼저 만들어 보관 기간을 7일로 둔다(설계 4.10 "CloudWatch Logs 7일").
# Fluent Bit 이 먼저 만들면 "만료 없음" 이 되어 로그가 영원히 쌓인다. 이름은 Add-on 이 쓰는 고정 규칙.
resource "aws_cloudwatch_log_group" "container_insights" {
  for_each = toset(["application", "dataplane", "host", "performance"])

  name              = "/aws/containerinsights/${aws_eks_cluster.this.name}/${each.key}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "/aws/containerinsights/${aws_eks_cluster.this.name}/${each.key}"
  }
}

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "amazon-cloudwatch-observability"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  # Application Signals(APM 추적) 는 쓰지 않는다. 기본값(enabled, autoMonitor.monitorAllServices = true)으로 두면 웹훅이 모든 Pod 에
  # 언어별 자동 계측 initContainer 4개(java, python, nodejs, dotnet)를 끼워 넣어 Pod 시작 시간 측정(2.1절)이 흐려지고 비용이 붙는다
  # (2026-10-27 backend Pod 가 Init:4/5 로 뜨는 것을 보고 확인). 둘 다 끈다. 지표(Container Insights)·로그(Fluent Bit)는 그대로.
  configuration_values = jsonencode({
    applicationSignals = { enabled = false }
    manager = {
      applicationSignals = {
        autoMonitor = { monitorAllServices = false }
      }
    }
  })

  # Add-on 이 만드는 ServiceAccount amazon-cloudwatch/cloudwatch-agent 에 위 역할을 연결. EKS 가 association 을 함께 만든다.
  pod_identity_association {
    role_arn        = aws_iam_role.cloudwatch_agent.arn
    service_account = "cloudwatch-agent"
  }

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_addon.pod_identity_agent, # 자격 증명을 받으려면 에이전트가 먼저
    aws_iam_role_policy_attachment.cloudwatch_agent,
    aws_cloudwatch_log_group.container_insights,
  ]
}
