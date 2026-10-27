# ---------------------------------------------------------------------------
# Argo CD: config 리포의 매니페스트를 클러스터에 자동 동기화하는 GitOps 컨트롤러 (설계 결정 18, 2026-10-27 Phase 1 편입).
# 흐름: 앱 리포 push → GitHub Actions(이미지 → ECR, config 리포 images: 태그 커밋) → Argo CD 가 config 리포 폴링 → kustomize 빌드 → sync.
#
# AWS 권한 없음: Argo CD 는 AWS API 를 부르지 않고(ECR 인증은 노드가 함), config 리포가 공개라 Git 자격 증명도 없다. 그래서 Pod Identity 가 없다.
# Application 오브젝트는 Terraform 이 만들지 않는다: kubernetes_manifest 는 plan 시점에 CRD 가 필요해 같은 apply 에서 깨진다.
#   config 리포 argocd/root.yaml 을 kubectl apply 1회(부트스트랩)하면 나머지 Application 은 Git 에서 온다(app-of-apps).
# 접근: kubectl -n argocd port-forward svc/argocd-server 8080:80 → http://localhost:8080 (README).
# ---------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version

  # 값이 많고 중첩이 깊어 set 리스트 대신 values 파일. 내용은 argocd-values.yaml 주석 참고.
  values = [file("${path.module}/argocd-values.yaml")]

  wait    = true
  timeout = 600
}
