# 다음 스택과 config 리포가 받아 쓰는 값 (architecture.md 6.4 표, 6.2 계약표).

# --- storage: S3 ---
output "photos_bucket_name" {
  description = "위반 사진 버킷 이름. config 리포 config.env 의 S3_BUCKET."
  value       = aws_s3_bucket.this["photos"].bucket
}

output "models_bucket_name" {
  description = "모델 버킷 이름. config 리포 initContainer 의 sync 원본, `aws s3 sync` 대상."
  value       = aws_s3_bucket.this["models"].bucket
}

output "photos_bucket_arn" {
  description = "cluster 스택 backend Pod Identity 정책(violations/* Put/Get/Head)."
  value       = aws_s3_bucket.this["photos"].arn
}

output "models_bucket_arn" {
  description = "cluster 스택 backend Pod Identity 정책(v*/ Get/List)."
  value       = aws_s3_bucket.this["models"].arn
}

# --- storage: ECR ---
# 형식 <계정ID>.dkr.ecr.<리전>.amazonaws.com/parking-guardian/<이름>. docker tag/push 대상이고 config.env 의 이미지 주소.
output "ecr_repository_urls" {
  description = "ECR 리포지토리 URL. 키 backend / frontend. PC 의 docker push 와 config 리포 config.env."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

# --- secrets ---
output "secret_names" {
  description = "Secrets Manager 비밀 이름. 키 app / seed. config 리포 externalsecret.yaml 과 put-secret-value 의 --secret-id."
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.name }
}

output "secret_arns" {
  description = "비밀 ARN. platform 스택 ESO Pod Identity 정책(Get/Describe). RDS 비밀 ARN 은 rds 단계에서 따로 출력."
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.arn }
}
