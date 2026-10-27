# ---------------------------------------------------------------------------
# 관리형 노드 그룹: EC2 인스턴스(Auto Scaling 그룹)를 EKS 가 대신 만들고 클러스터에 붙인다.
# m7i-flex.large ×2 = 시간당 약 $0.24 (월 $172. 설계의 m7i.large 는 Free 플랜에서 불가, variables.tf). 노드 비용만 끄려면 desired 를 0 으로 apply(클러스터는 남아 $0.10/h).
#
# 구성 3개: 노드 IAM 역할 → Launch Template(디스크, SG, IMDS) → 노드 그룹(인스턴스 수·타입·Subnet)
#
# Launch Template 을 따로 쓰는 이유: 노드 그룹 리소스만으로는 디스크 크기와 "추가 SG" 를 지정할 수 없다.
# 주의: Launch Template 에 SG 를 적으면 EKS 가 클러스터 SG 를 자동으로 붙여 주지 않는다. 그래서 둘 다 명시한다.
# ---------------------------------------------------------------------------

# < 노드 IAM 역할 > kubelet 이 클러스터에 등록하고, ECR 에서 이미지를 받고, VPC CNI 가 ENI·IP 를 다루고, SSM 으로 접속하기 위한 권한.
# Pod 의 AWS 권한(S3 등)은 여기 없다. Pod Identity 가 Pod 별 역할을 따로 준다(iam.tf). 노드 역할은 "노드 운영" 만.
data "aws_iam_policy_document" "eks_node_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.project_name}-eks-node"
  description        = "EKS worker node role (kubelet, CNI, ECR pull, SSM)"
  assume_role_policy = data.aws_iam_policy_document.eks_node_trust.json

  tags = {
    Name = "${var.project_name}-eks-node"
  }
}

# AWS 관리형 정책 4개. for_each 로 정책마다 attachment 하나.
#   WorkerNodePolicy        kubelet 이 EC2·EKS API 로 자기 정보를 조회하고 클러스터에 등록
#   EKS_CNI_Policy          VPC CNI 가 ENI 를 만들고 Pod IP 를 할당
#   ContainerRegistryPullOnly  ECR 이미지 Pull(푸시 없음)
#   SSMManagedInstanceCore  SSM Session Manager 로 노드 셸 접속(SSH 키·22 포트 없음. 설계 4.3)
resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}

# < Launch Template > 인스턴스의 디스크·SG·메타데이터 설정. AMI 와 부트스트랩은 적지 않는다(EKS 가 AL2023 AMI 와 nodeadm 설정을 채운다).
resource "aws_launch_template" "eks_node" {
  name_prefix = "${var.project_name}-eks-node-"
  description = "EKS managed node group: gp3 root volume, node SG, IMDSv2"

  # 루트 볼륨. AL2023 EKS AMI 의 루트 디바이스는 /dev/xvda.
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_gb
      volume_type           = "gp3"
      encrypted             = true # AWS 관리형 키(aws/ebs). 비용 없음
      delete_on_termination = true
    }
  }

  # 클러스터 SG(EKS 생성: 노드 ↔ 컨트롤 플레인·노드 ↔ 노드) + node SG(network: alb 에서 5000·8080, 아웃바운드 전체).
  vpc_security_group_ids = [
    aws_eks_cluster.this.vpc_config[0].cluster_security_group_id,
    var.node_security_group_id,
  ]

  # IMDSv2 만 허용(토큰 필수). hop limit 2 는 EKS 기본값: 노드 위 컨테이너(브리지 네트워크, 홉 1개 추가)도 IMDS 에 닿을 수 있다.
  # 1 로 줄이면 Pod 가 노드 역할을 훔쳐 쓰는 것을 막지만, 일부 시스템 에이전트가 IMDS 를 쓰므로 Phase 1 은 기본값.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  # 상세 모니터링(1분 간격)은 유료. 기본 5분으로.
  monitoring {
    enabled = false
  }

  # 인스턴스와 볼륨에 붙는 태그(default_tags 는 Launch Template 자체에만 붙고 인스턴스에는 전파되지 않는다).
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name      = "${var.project_name}-node"
      Project   = var.project_name
      Phase     = "1"
      ManagedBy = "terraform"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name      = "${var.project_name}-node"
      Project   = var.project_name
      Phase     = "1"
      ManagedBy = "terraform"
    }
  }

  # 변경 시 새 버전을 먼저 만들고 노드 그룹이 그걸 가리킨 뒤 옛 버전을 지운다.
  lifecycle {
    create_before_destroy = true
  }
}

# < 노드 그룹 > 생성 3~5분. 노드가 Ready 될 때까지 기다린다.
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project_name}-main"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = var.private_app_subnet_ids # AZ a, c 에 분산

  # AL2023 x86_64 표준 AMI. 클러스터 버전에 맞는 최신 AMI 를 EKS 가 고른다(release_version 미지정).
  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = [var.node_instance_type]
  capacity_type  = "ON_DEMAND" # Spot 은 Phase 2 (설계 5절)

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # 노드 그룹 업데이트(AMI 교체 등) 때 한 번에 내리는 노드 수. 노드 2대 중 1대씩.
  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.eks_node.id
    version = aws_launch_template.eks_node.latest_version
  }

  labels = {
    "parking-guardian/node-group" = "main"
  }

  tags = {
    Name = "${var.project_name}-main"
  }

  # Cluster Autoscaler 같은 외부 도구가 desired 를 바꿀 때 Terraform 이 되돌리지 않게 하는 관례.
  # 지금은 Autoscaler 가 없지만, 측정 때 콘솔·CLI 로 노드를 3대로 늘리는 경우를 위해 둔다. 되돌리려면 tfvars 로 apply.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  # 정책이 붙은 뒤 노드가 뜨고, 지울 때는 노드가 사라진 뒤 정책을 뗀다.
  depends_on = [aws_iam_role_policy_attachment.eks_node]
}
