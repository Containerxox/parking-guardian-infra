# ---------------------------------------------------------------------------
# EKS 클러스터 = 컨트롤 플레인(API 서버, etcd, 스케줄러 등. AWS 가 운영). 시간당 $0.10 (월 $73). 생성 8~12분.
# 노드는 다음 조각(nodes.tf). 노드가 없어도 클러스터는 비용이 든다.
#
# 컨트롤 플레인은 AWS 소유 VPC 에서 돌고, 우리 VPC 의 Private App Subnet 에 ENI 를 몇 개 꽂아 노드와 통신한다.
# 그 ENI 에 붙는 SG(클러스터 SG)는 EKS 가 만들어 노드에도 자동으로 붙인다. 노드 ↔ 컨트롤 플레인, 노드 ↔ 노드 통신은
# 그 SG 가 담당하고, network 스택의 node SG 는 ALB·RDS 와의 경계만 맡는다(security_groups.tf 머리말).
# ---------------------------------------------------------------------------

# < 클러스터 IAM 역할 > 컨트롤 플레인이 우리 계정의 ENI·SG·ELB 등을 다룰 때 쓰는 역할. 신뢰 주체는 eks 서비스.
data "aws_iam_policy_document" "eks_cluster_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.project_name}-eks-cluster"
  description        = "EKS control plane role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_trust.json

  tags = {
    Name = "${var.project_name}-eks-cluster"
  }
}

# AWS 관리형 정책 1개로 충분하다(ENI·SG 관리, CloudWatch 로그, ELB 조회 등).
resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# < 클러스터 >
resource "aws_eks_cluster" "this" {
  name     = var.project_name
  version  = var.eks_version
  role_arn = aws_iam_role.eks_cluster.arn

  # 표준 지원만. 표준 지원이 끝나면 자동으로 확장 지원(6배 요금)으로 넘어가지 않고 업그레이드를 요구한다.
  upgrade_policy {
    support_type = "STANDARD"
  }

  # < 인증 모드 API > (설계 4.3) 누가 kubectl 을 쓸 수 있는지를 aws-auth ConfigMap 이 아니라 EKS Access Entry 로 관리한다.
  # bootstrap_...=true: 클러스터를 만든 신원(Terraform 실행자 PG_test)에게 자동으로 cluster-admin 을 준다.
  # 다른 사용자를 추가하려면 aws_eks_access_entry 리소스를 쓴다(이 스택에서 코드로).
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    # 컨트롤 플레인 ENI 가 놓이는 Subnet. Private App Subnet a, c (AZ 2개 필수).
    subnet_ids = var.private_app_subnet_ids

    # 엔드포인트 Public + Private (설계 4.2).
    #   Private: 노드·Pod 가 VPC 안에서 API 서버에 접근(인터넷 안 거침).
    #   Public : 관리자 PC 의 kubectl. public_access_cidrs 로 IP 제한. IP 가 바뀌면 tfvars 만 고친다.
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.eks_public_access_cidrs
  }

  # Pod IP 대역이 아니라 Service(ClusterIP) 대역. VPC CIDR(10.0.0.0/16)과 겹치지 않게 둔다.
  kubernetes_network_config {
    service_ipv4_cidr = "172.20.0.0/16"
    ip_family         = "ipv4"
  }

  # 컨트롤 플레인 로그. 기본 비움(비용). 켜면 CloudWatch Logs 그룹 /aws/eks/<이름>/cluster 로 간다.
  enabled_cluster_log_types = var.eks_cluster_log_types

  # etcd 의 Secret 봉투 암호화에 고객 관리형 KMS 키를 쓰지 않는다(결정 23). EKS 기본(AWS 소유 키) 그대로.

  tags = {
    Name = var.project_name
  }

  # 역할에 정책이 붙은 뒤 클러스터를 만들고, 지울 때는 클러스터가 먼저 사라진 뒤 정책을 뗀다(ENI 정리에 권한이 필요).
  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}
