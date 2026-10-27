# S3 버킷 이름 출력
output "state_bucket_name" {
  description = "다른 스택의 backend bucket."
  value       = aws_s3_bucket.state.bucket
}

# AWS 리전 출력
output "aws_region" {
  description = "다른 스택의 backend region."
  value       = var.aws_region
}

# 다른 스택이 공유하는 backend.hcl 의 내용. 계정 ID 가 들어가므로 파일은 .gitignore 대상이다.
#   terraform output -raw backend_hcl | Out-File -Encoding ascii ..\..\backend.hcl   (PowerShell)
#   terraform output -raw backend_hcl > ../../backend.hcl                              (Git Bash)
output "backend_hcl" {
  description = "terraform/backend.hcl 로 저장할 내용. 각 스택은 terraform init -backend-config=../../backend.hcl 로 쓴다."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.bucket}"
    region       = "${var.aws_region}"
    encrypt      = true
    use_lockfile = true
  EOT
}
