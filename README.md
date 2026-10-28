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

## 2. network

VPC 와 그 안의 네트워크 골격. 수명이 길고 **비용 0** 인 것만 둔다. 비용이 드는 NAT Gateway 는 매일 지우는 `cluster` 스택 소속이다. 앞 스택에서 받는 값은 없고 변수 파일도 필요 없다(기본값이 설계값).

```powershell
$env:AWS_PROFILE = "parking-guardian"
aws sts get-caller-identity          # 계정·사용자 확인
cd terraform\stacks\network
terraform init -backend-config=..\..\backend.hcl
terraform plan
terraform apply
terraform plan                       # 완료 기준: "No changes."
```

만드는 것(30개 리소스):

| 파일 | 리소스 |
|---|---|
| `vpc.tf` | VPC `10.0.0.0/16`, DNS support·hostnames 활성 |
| `subnets.tf` | Subnet 6개. Public `/24` ×2(`kubernetes.io/role/elb=1`), Private App `/20` ×2(`kubernetes.io/role/internal-elb=1`), Private DB `/24` ×2. AZ `a`, `c` |
| `routes.tf` | Internet Gateway 1개, 라우트 테이블 3개(public: `0.0.0.0/0 → IGW`, private-app·private-db: local 만), Subnet 연결 6개 |
| `endpoints.tf` | S3 Gateway Endpoint. Private App 라우트 테이블에만 연결 |
| `security_groups.tf` | SG 3개와 규칙 8개. `alb`(0.0.0.0/0 → 443, 80) → `node`(5000, 8080) → `rds`(5432). node 아웃바운드 전체 허용, rds 아웃바운드 없음 |

CIDR 배치: Private App `10.0.0.0/20`(a), `10.0.16.0/20`(c). Public `10.0.32.0/24`, `10.0.33.0/24`. Private DB `10.0.40.0/24`, `10.0.41.0/24`. `10.0.48.0` 이후는 비워 둔다.

라우트와 SG 규칙은 inline 블록이 아니라 별도 리소스(`aws_route`, `aws_vpc_security_group_*_rule`)로 쓴다. `cluster` 스택이 Private App 라우트 테이블에 넣는 NAT 경로와 AWS Load Balancer Controller 가 런타임에 추가하는 SG 규칙을 이 스택의 `plan` 이 지우지 않게 하기 위해서다.

### 출력값과 다음 스택

스택 사이 값 전달은 `terraform output` → 다음 스택의 `terraform.tfvars`(gitignore). 어느 스택이 어느 값을 쓰는지:

| 출력 | 쓰는 곳 |
|---|---|
| `vpc_id` | `data`(RDS 서브넷 그룹), `cluster`(EKS), `platform`(ALB Controller) |
| `private_db_subnet_ids`, `rds_security_group_id` | `data`(RDS) |
| `public_subnet_ids`, `private_app_subnet_ids`, `node_security_group_id`, `private_app_route_table_id` | `cluster`(NAT 위치, EKS 클러스터·노드 그룹, NAT 경로) |
| `alb_security_group_id` | config 리포 Ingress 어노테이션 `alb.ingress.kubernetes.io/security-groups` |
| `vpc_cidr`, `s3_endpoint_prefix_list_id` | 참고용(SG 규칙 좁힐 때) |

값은 `terraform output -json` 으로 한 번에 볼 수 있다. ID 는 `docs/` 나 tfvars 에만 적고 README·커밋에 넣지 않는다.

삭제: `cluster` 와 `data` 를 먼저 지운 뒤 `terraform destroy`. RDS·노드·NAT 가 남아 있으면 Subnet·SG 삭제가 실패한다.

## 3. data

수명이 긴 데이터·계정 자원. `cluster` 를 매일 지워도 이 스택은 유지한다. network 스택의 출력값 2개를 `terraform.tfvars` 로 받는다.

```powershell
$env:AWS_PROFILE = "parking-guardian"
aws sts get-caller-identity
cd terraform\stacks\data
Copy-Item terraform.tfvars.example terraform.tfvars      # 처음 한 번. 이메일과 network 출력값을 채운다
terraform init -backend-config=..\..\backend.hcl
terraform plan
terraform apply
terraform plan                                           # 완료 기준: "No changes."
```

`terraform.tfvars` 에 들어가는 값(gitignore):

| 변수 | 출처 |
|---|---|
| `budget_alert_emails` | 경보 받을 이메일 |
| `private_db_subnet_ids` | `terraform -chdir=..\network output -json private_db_subnet_ids` |
| `rds_security_group_id` | `terraform -chdir=..\network output -raw rds_security_group_id` |
| `domain_name` | 외부 등록기관(가비아)에서 산 도메인. 코드·README 에 적지 않는다 |

만드는 것(27개 리소스):

| 파일 | 리소스 |
|---|---|
| `budget.tf` | Budgets 월 $100, 실제 누적 $50·$100 도달 시 이메일. 크레딧·환불 제외 집계. 자동 조치 없음 |
| `storage_s3.tf` | S3 `parking-guardian-photos-<계정ID>`, `parking-guardian-models-<계정ID>`. 소유권 강제, 퍼블릭 차단, SSE-S3, HTTPS 전용. 버전 관리·Lifecycle 없음 |
| `storage_ecr.tf` | ECR `parking-guardian/backend`, `parking-guardian/frontend`. 태그 불변, 푸시 시 스캔, untagged 1일·태그 최근 10개 유지 |
| `secrets.tf` | Secrets Manager `parking-guardian/app`(SECRET_KEY, JWT_SECRET), `parking-guardian/seed`(SEED_ADMIN_PASSWORD, SEED_DEVICE_KEY_SECRET). 빈 컨테이너, 삭제 유예 7일 |
| `rds.tf` | DB 서브넷 그룹(Private DB Subnet a·c), 파라미터 그룹 postgres16(`rds.force_ssl=1`), 인스턴스 `parking-guardian`: PostgreSQL 16, `db.t4g.micro`, Single-AZ, gp3 20 GB, 암호화, 공개 접근 없음, 관리형 마스터 비밀번호, 백업 1일, 삭제 보호, 최종 스냅샷 |
| `dns.tf` | Route 53 Hosted Zone `<domain_name>`, ACM 인증서 `parking.<domain_name>`(DNS 검증, 서울 리전), 검증 CNAME, 검증 완료 대기 |

**설계와 다른 점**: Cost Anomaly Detection 은 범위에서 뺐다(AWS 기본 모니터만 남김). RDS 자동 백업은 설계 7일이었으나 AWS Free 플랜 상한이 1일이다. 도메인은 Free 플랜에서 Route 53 도메인 등록(Route 53 Domains)이 안 되어 **외부 등록기관(가비아)에서 사고 NS 만 Route 53 영역으로 위임**한다.

### apply 뒤 수동 작업 (Terraform 밖)

**모델 업로드** 1회. 모델은 Git 에 없어 Terraform 이 못 올린다.

```powershell
$models = terraform output -raw models_bucket_name
aws s3 sync <앱 리포>\backend\models "s3://$models/v1/" --exclude "*" --include "default.pt" --include "last.pt"
aws s3 ls "s3://$models/v1/"                             # default.pt, last.pt
```

**비밀 값 주입** 1회. JSON 파일에 값을 쓰고 넣은 뒤 파일을 즉시 지운다. 값은 어디에도 기록하지 않는다.

```powershell
# app.json:  {"SECRET_KEY":"...","JWT_SECRET":"..."}     seed.json: {"SEED_ADMIN_PASSWORD":"...","SEED_DEVICE_KEY_SECRET":"..."}
# grafana.json: {"admin-user":"admin","admin-password":"..."}   (모니터링. Grafana 로그인. 키 이름은 차트가 기대하는 그대로)
aws secretsmanager put-secret-value --secret-id parking-guardian/app     --secret-string file://app.json
aws secretsmanager put-secret-value --secret-id parking-guardian/seed    --secret-string file://seed.json
aws secretsmanager put-secret-value --secret-id parking-guardian/grafana --secret-string file://grafana.json
Remove-Item app.json, seed.json, grafana.json
```

RDS 마스터 비밀번호는 RDS 가 만들어 Secrets Manager 에 두므로 넣을 것이 없다(`db_master_secret_arn`).

**RDS 정지**: 쓰지 않을 때 `aws rds stop-db-instance --db-instance-identifier parking-guardian`. 7일 뒤 자동 재시작된다. 시작은 `start-db-instance`.

### 출력값과 다음 스택

| 출력 | 쓰는 곳 |
|---|---|
| `photos_bucket_arn`, `models_bucket_arn` | `cluster`(backend Pod Identity 정책) |
| `secret_arns`(app, seed), `db_master_secret_arn` | `platform`(ESO Pod Identity 정책) |
| `photos_bucket_name`, `models_bucket_name`, `ecr_repository_urls`, `secret_names`, `db_host`, `db_port`, `db_name` | config 리포 `config.env`(ConfigMap), `externalsecret.yaml`, PC 의 `docker push` |
| `acm_certificate_arn`, `app_fqdn` | config 리포 `ingress.yaml`(certificate-arn, host), `config.env` 의 `CORS_ORIGINS` |
| `route53_zone_id`, `app_fqdn` | `dns-record`(Alias 레코드) |
| `route53_name_servers` | 등록기관 네임서버 설정(아래) |

### dns: 영역 먼저, NS 위임 뒤 인증서

인증서의 DNS 검증은 등록기관이 우리 영역으로 NS 를 위임한 뒤에만 통과한다. 한 번에 apply 하면 `aws_acm_certificate_validation` 이 기다리다 타임아웃(75분)으로 실패하므로 두 번에 나눈다. PowerShell 에서는 `-target` 값을 인용부호로 감싼다(`.this` 가 잘린다).

```powershell
terraform apply -target="aws_route53_zone.this"            # 1차: 영역만
terraform output route53_name_servers                      # NS 4개
# 등록기관(가비아 My가비아 → 도메인 관리 → 네임서버 설정)에 4개를 등록. 끝의 점은 뺀다
nslookup -type=NS <도메인> 1.1.1.1                          # 4개가 같아지면 전파 완료. 8.8.8.8 은 옛 값을 최대 2일 캐시한다
terraform apply                                            # 2차: 인증서·검증 레코드. ISSUED 까지 수 분
terraform output acm_certificate_arn
```

ALB 를 가리키는 Alias 레코드는 여기 없다. ALB 가 생긴 뒤 `dns-record` 스택이 만든다.

### 삭제

`cluster`·`platform` 을 먼저 지운다. 그 뒤 ① `db_deletion_protection = false` 로 apply, ② 같은 이름의 최종 스냅샷(`parking-guardian-final`)이 남아 있으면 삭제, ③ S3 버킷을 비우고 ECR 이미지를 지운 뒤 `terraform destroy`. 영역이 사라지면 등록기관의 NS 위임은 허공을 가리키므로 도메인을 계속 쓰려면 영역을 남기거나(`-target` 제외) 등록기관 NS 를 되돌린다. 비밀은 7일 유예 뒤 사라지며, 같은 이름을 바로 다시 만들려면 `delete-secret --force-delete-without-recovery`.

## 4. cluster

비용이 큰 것. **쓸 때 apply, 끝나면 destroy**(또는 노드만 0대로). network·data 는 그대로 두고 이 스택만 매일 만들고 지운다.

| 리소스 | 시간당 | 24시간 월 |
|---|---|---|
| EKS 컨트롤 플레인 | $0.10 | $73 |
| 노드 m7i-flex.large ×2 | 약 $0.24 | 약 $172 |
| NAT Gateway | 약 $0.059 + GB | 약 $43 |
| CloudWatch(Container Insights, 로그 7일) | | 약 $10~20 |

```powershell
$env:AWS_PROFILE = "parking-guardian"
aws sts get-caller-identity
cd terraform\stacks\cluster
Copy-Item terraform.tfvars.example terraform.tfvars       # 처음 한 번. 아래 표의 값을 채운다
terraform init -backend-config=..\..\backend.hcl
terraform apply                                           # 15~20분 (EKS 10분 + 노드 5분 + Add-on 3분)
terraform plan                                            # 완료 기준: "No changes."

aws eks update-kubeconfig --name parking-guardian --region ap-northeast-2
kubectl get nodes                                         # 2대 Ready
kubectl get pods -A                                       # kube-system 9개 + amazon-cloudwatch 5개 Running
aws eks list-pod-identity-associations --cluster-name parking-guardian   # cloudwatch-agent, backend
```

`terraform.tfvars` 에 들어가는 값(gitignore):

| 변수 | 출처 |
|---|---|
| `public_subnet_ids`, `private_app_subnet_ids`, `private_app_route_table_id`, `node_security_group_id` | `terraform -chdir=..\network output` |
| `photos_bucket_arn`, `models_bucket_arn` | `terraform -chdir=..\data output` |
| `eks_public_access_cidrs` | 관리자 PC 공인 IP `/32` (`curl https://checkip.amazonaws.com`). IP 가 바뀌면 이 값만 고쳐 apply |

만드는 것(32개 리소스):

| 파일 | 리소스 |
|---|---|
| `nat.tf` | EIP 1개, NAT Gateway 1개(Public Subnet a), network 소유 Private App 라우트 테이블에 `0.0.0.0/0 → NAT` 경로(`aws_route`) |
| `eks.tf` | 클러스터 IAM 역할, EKS 1.35. 인증 모드 API(생성자 자동 admin), 엔드포인트 Private + Public(관리자 IP 제한), Service CIDR `172.20.0.0/16`, 표준 지원만, 컨트롤 플레인 로그 끔 |
| `nodes.tf` | 노드 IAM 역할(WorkerNode, CNI, ECR PullOnly, SSM), Launch Template(gp3 50 GB 암호화, 클러스터 SG + network node SG, IMDSv2), 관리형 노드 그룹 `parking-guardian-main`(AL2023 x86_64, desired 2 / min 0 / max 3) |
| `addons.tf` | 관리형 Add-on 6개(vpc-cni, kube-proxy, coredns, eks-pod-identity-agent, metrics-server, amazon-cloudwatch-observability), CloudWatch 에이전트 Pod Identity 역할, Container Insights 로그 그룹 4개(7일) |
| `iam.tf` | backend Pod Identity 역할(사진 `violations/*` Put/Get, 모델 `v*/` List/Get) + 연결(`parking-guardian`/`backend`) |

**설계와 다른 점**: 노드는 설계 `m7i.large` 가 아니라 **`m7i-flex.large`**. AWS Free 플랜은 Free Tier 적격 인스턴스 타입만 띄울 수 있고(Auto Scaling 오류 "not eligible for Free Tier"), 서울 리전 적격 x86 타입 중 8 GiB 는 이것 하나다. flex 는 평균 사용률 40% 전제라 추론이 CPU 를 오래 채우면 `m7i.large` 보다 느릴 수 있다. 측정 기록에 적는다.

### 비용 끄기

| 방법 | 남는 비용 | 복구 |
|---|---|---|
| 노드만 0대 | 컨트롤 플레인 $0.10/h + NAT $0.06/h | `desiredSize=2` 로 되돌림(1~3분) |
| 스택 destroy | 0 (network·data 만 남음) | `terraform apply`(15~20분) + platform·config 다시 적용 |

```powershell
# 노드만. desired_size 는 Terraform 이 ignore_changes 라 plan 이 바뀌지 않는다
aws eks update-nodegroup-config --cluster-name parking-guardian --nodegroup-name parking-guardian-main --scaling-config desiredSize=0
```

### 중단된 apply 복구

노드 그룹처럼 오래 걸리는 생성 중에 Ctrl+C 로 끊으면, 그 전에 만들어진 리소스(IAM 역할, Launch Template)가 AWS 에는 있고 State 에는 없을 수 있다. 다시 apply 하면 "already exists" 로 실패한다. 순서: ① Terraform 프로세스가 정말 없는지 확인(작업 관리자에서 `terraform`, `terraform-provider-aws`) ② 남은 잠금은 `terraform force-unlock <ID>`(ID 는 오류 메시지에) ③ AWS 에 남은 것을 `terraform import` ④ `plan` 으로 교체·변경 범위 확인 뒤 apply. import 주소 예: `aws_iam_role.eks_node parking-guardian-eks-node`, `aws_eks_node_group.main parking-guardian:parking-guardian-main`, `aws_launch_template.eks_node lt-xxxx`.

### 출력값과 다음 스택

| 출력 | 쓰는 곳 |
|---|---|
| `cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data` | `platform`(helm·kubernetes provider) |
| `cluster_name` | config 리포(`aws eks update-kubeconfig`) |
| `nat_public_ip` | 외부 서비스 IP 허용 목록(노드·Pod 의 아웃바운드 주소) |
| `cluster_security_group_id`, `node_group_name`, `node_role_arn`, `backend_role_arn` | 참고·운영 명령 |

### 삭제

config 리포의 Ingress 가 지워져 ALB 가 사라진 것을 확인하고 `platform` 스택을 지운 뒤 `terraform destroy`. ALB 가 남아 있으면 Subnet·SG 삭제가 실패하고(network 는 유지하지만 NAT 의 EIP 해제도 막힐 수 있다), ESO·ALB Controller 의 Pod Identity 연결은 platform 이 거둔다. NAT 경로는 함께 사라져 Private App Subnet 은 "인터넷 경로 없음" 으로 돌아간다(S3 Endpoint 경로는 남는다).

## 5 이후

작성 예정. 순서와 각 단계의 입력·완료 기준은 설계 문서를 따른다.
