# parking-guardian-infra

Parking Guardian 의 AWS 인프라(Terraform). 이 리포에는 Terraform 코드만 둔다. 설계 문서(`docs/`), 변수 값(`*.tfvars`), backend 설정(`terraform/backend.hcl`), State 는 Git 에 올리지 않는다.

Kubernetes 매니페스트는 `parking-guardian-config` 리포, 앱 코드는 `parking-guardian` 리포에 있다.

## 사전 조건

- Terraform 1.10 이상 (S3 backend 의 `use_lockfile` 사용. DynamoDB 잠금 테이블 없음)
- AWS CLI v2. Terraform 전용 IAM 사용자의 Access Key 를 `aws configure` 로 등록(리전 `ap-northeast-2`)
- 환경은 하나다(dev / prod 구분 없음)

## 인증

Terraform 전용 IAM 사용자의 Access Key 는 AWS CLI 의 **`parking-guardian` 프로필**에 등록한다(기본 프로필이 아니다).

```powershell
aws configure --profile parking-guardian    # Access Key, Secret Key, 리전 ap-northeast-2
```

Terraform 은 AWS CLI 와 같은 **기본 자격 증명 체인**을 쓴다. 프로필은 코드가 아니라 **환경변수 `AWS_PROFILE`** 로 고른다. provider 블록에는 `access_key`, `secret_key`, `profile` 을 적지 않는다. 키를 Terraform 코드, `tfvars`, Git 에 넣지 않는다.

```powershell
$env:AWS_PROFILE = "parking-guardian"       # PowerShell. 터미널을 새로 열면 다시 설정
```

```bash
export AWS_PROFILE=parking-guardian         # Git Bash
```

코드가 특정 사용자나 프로필 이름에 묶여 있지 않으므로, 뒤에 최소 권한 정책을 붙이거나 IAM Role 임시 자격 증명(`role_arn` 이 있는 프로필)으로 바꿀 때는 프로필 내용이나 `AWS_PROFILE` 값만 바꾸면 되고 Terraform 코드는 바뀌지 않는다.

**모든 `terraform` 명령 전에 신원을 확인한다.** 이 PC 에는 다른 프로젝트의 프로필도 있고 기본 프로필은 다른 사용자이므로, `AWS_PROFILE` 을 빠뜨리면 다른 신원으로 실행된다.

```powershell
aws sts get-caller-identity
```

출력의 `Account` 가 Parking Guardian 계정이고 `Arn` 이 `arn:aws:iam::<계정ID>:user/<Terraform 전용 사용자>` 인지 본다. 다른 계정이나 다른 사용자가 나오면 `AWS_PROFILE` 을 다시 설정한 뒤 확인한다. 다른 계정에 apply 하면 그 계정에 리소스가 생기고 State 버킷도 거기 만들어진다.

## 스택 순서

State 는 스택마다 따로다(같은 버킷, 다른 key). 스택 사이 값 전달은 `terraform output` → 다음 스택의 변수.

| 순서 | 스택 | 역할 | State |
|---|---|---|---|
| 1 | `bootstrap` | State 버킷(S3, SSE-S3, 버전 관리) | 로컬 |
| 2 | `network` | VPC, Subnet, 라우트, S3 Gateway Endpoint, SG | S3 |
| 3 | `data` | Budgets, Route 53 영역·ACM, S3 ×2, ECR ×2, Secrets Manager(빈 컨테이너), RDS | S3 |
| 4 | `cluster` | NAT, EKS, 노드 그룹, 관리형 Add-on, IAM·Pod Identity, CloudWatch | S3 |
| 5 | `platform` | Helm: AWS Load Balancer Controller, External Secrets Operator | S3 |
| 6 | `dns-record` | Ingress 로 ALB 가 생긴 뒤 Route 53 Alias | S3 |

삭제는 역순. 단, `dns-record` 는 가장 먼저 지운다(ALB 가 사라지면 조회가 실패한다).

## 1. bootstrap

다른 스택의 State 를 담을 버킷을 만든다. 이 스택만 로컬 State(`terraform.tfstate`, gitignore)를 쓴다. 계정 ID 는 코드에 없고 실행 신원에서 읽는다. 변수 파일은 필요 없다.

```powershell
$env:AWS_PROFILE = "parking-guardian"
aws sts get-caller-identity          # 계정·사용자 확인 (위 "인증" 절)
cd terraform\stacks\bootstrap
terraform init
terraform plan
terraform apply
```

만드는 것: S3 버킷 `parking-guardian-tfstate-<계정ID>` 1개(버전 관리, SSE-S3 AES-256, 퍼블릭 차단, ACL 비활성, HTTPS 전용, 이전 버전 90일 뒤 삭제, S3 네이티브 잠금). AWS Free Plan 을 유지하므로 KMS 고객 관리형 키는 쓰지 않는다.

apply 뒤 다른 스택이 공유하는 backend 설정 파일을 만든다. 이 파일에는 계정 ID 가 들어가므로 gitignore 대상이다.

```powershell
# PowerShell (BOM 없이 저장)
terraform output -raw backend_hcl | Out-File -Encoding ascii ..\..\backend.hcl
```

```bash
# Git Bash
terraform output -raw backend_hcl > ../../backend.hcl
```

형식은 `terraform/backend.hcl.example` 참고. 이후 스택은 모두 다음처럼 초기화한다.

```powershell
cd terraform\stacks\network
terraform init -backend-config=..\..\backend.hcl
```

끝났다는 기준: 다음 스택의 `terraform init` 이 성공하고 버킷에 `<스택>/terraform.tfstate` 가 생긴다.

전체 삭제 때: 버킷에 `prevent_destroy` 가 걸려 있다. 다른 스택을 모두 지우고 버킷을 비운 뒤, `main.tf` 의 `prevent_destroy` 줄을 지우고 `terraform destroy` 한다.

계정이 AWS Organizations 의 멤버이면 SCP 가 S3·KMS 를 막을 수 있다. `aws s3api list-buckets` 가 "explicit deny in a service control policy" 로 실패하면 관리 계정에서 SCP 를 고친 뒤 apply 한다.

## 2 이후

작성 예정. 순서와 각 단계의 입력·완료 기준은 설계 문서를 따른다.
