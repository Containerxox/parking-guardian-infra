# --- argocd ---
output "argocd_access" {
  description = "Argo CD UI 접근 방법. Ingress 없음."
  value       = "kubectl -n argocd port-forward svc/argocd-server 8080:80  →  http://localhost:8080  (admin / kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
}
