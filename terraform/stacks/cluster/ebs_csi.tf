# ---------------------------------------------------------------------------
# < EBS CSI 드라이버 > PersistentVolume 을 EBS 로 만들어 주는 Add-on. 모니터링(Prometheus TSDB)이 첫 사용자다. 2026-10-28.
#
# 왜 필요한가: 클러스터에 StorageClass gp2(provisioner kubernetes.io/aws-ebs)가 기본으로 있지만, 그 "in-tree" 프로비저너는
#   Kubernetes 1.27 에서 제거됐다. 지금 PVC 를 만들면 영원히 Pending 이다. CSI 드라이버가 있어야 실제로 볼륨이 생긴다.
#   StorageClass(gp3) 자체는 Kubernetes 오브젝트라 config 리포(platform/)에 둔다. 여기는 드라이버와 IAM 만.
#
# 권한: 드라이버의 컨트롤러(kube-system/ebs-csi-controller-sa)가 EC2 API 로 볼륨을 만들고 노드에 붙인다. AWS 관리형 정책
#   AmazonEBSCSIDriverPolicy 를 Pod Identity 로 준다(CloudWatch Add-on 과 같은 방식, 역할 ARN 어노테이션 없음).
#   노드 역할에는 주지 않는다: 노드의 모든 Pod 가 볼륨을 만들 수 있게 되기 때문.
#
# 비용: 드라이버 자체는 무료. 볼륨은 gp3 GB 당 월 약 $0.08(10 GiB ≈ $0.8/월). 클러스터 destroy 때 PVC 의 reclaimPolicy Delete 로
#   같이 지워진다 — 단, Namespace 가 PVC 보다 먼저 사라지면 고아 볼륨이 남을 수 있으니 teardown 뒤 `aws ec2 describe-volumes
#   --filters Name=tag:kubernetes.io/cluster/parking-guardian,Values=owned` 로 확인한다(README).
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.project_name}-ebs-csi"
  description        = "Pod Identity role for the EBS CSI driver add-on (kube-system/ebs-csi-controller-sa)"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json # addons.tf 의 공용 신뢰 정책(pods.eks.amazonaws.com)

  tags = {
    Name = "${var.project_name}-ebs-csi"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  # 컨트롤러는 기본 2 replica 다. 노드 3대에 Pod 2개면 충분하고 메모리만 수십 MB 라 기본값을 둔다.
  # 노드마다 뜨는 ebs-csi-node DaemonSet 은 볼륨을 노드에 마운트하는 역할. CPU 요청은 작다(기본 10m 수준).

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_addon.pod_identity_agent, # 자격 증명을 받으려면 에이전트가 먼저
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}
