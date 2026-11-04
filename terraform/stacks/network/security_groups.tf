# ---------------------------------------------------------------------------
# Security Group: 인스턴스·ENI 단위의 상태 유지(stateful) 방화벽. 허용 규칙만 있고 거부는 없다.
# 요청을 허용하면 응답은 자동으로 허용된다(그래서 egress 에 "응답" 규칙을 적지 않는다).
#
# 사슬 (architecture.md 4.2):
#   인터넷 0.0.0.0/0 ──443,80──► alb ──5000,8080──► node ──5432──► rds
#
# 규칙의 소스를 CIDR 이 아니라 "다른 SG" 로 적는 것이 핵심이다.
#   "node 에 5000 을 허용하는 소스 = alb SG" → ALB 의 IP 가 바뀌어도, ALB 가 여러 개여도 규칙이 유효하다.
#   Pod 는 노드의 ENI 에 붙고(VPC CNI) 노드 SG 를 그대로 쓰므로, ALB 가 IP 타깃 모드로 Pod IP 에 직접 보내도 node SG 가 받는다.
#
# 각 SG 는 어느 스택이 어디에 붙이는가:
#   alb   platform 스택 뒤, config 리포의 Ingress 어노테이션(alb.ingress.kubernetes.io/security-groups)
#   node  cluster 스택의 노드 그룹 launch template (EKS 가 만드는 클러스터 SG 에 "추가" 로 붙는다)
#   rds   data 스택의 RDS 인스턴스
#
# 규칙을 aws_security_group 안의 inline ingress/egress 블록이 아니라 별도 리소스
# (aws_vpc_security_group_ingress_rule / egress_rule)로 쓴다. 이유는 routes.tf 와 같다:
#   inline 으로 적으면 Terraform 이 그 SG 의 모든 규칙을 관리해서, AWS Load Balancer Controller 가
#   런타임에 node SG 에 추가하는 규칙을 다음 plan 이 지워 버린다. 별도 리소스면 내가 적은 규칙만 관리한다.
#   또 규칙 하나 = 리소스 하나라서 plan 에 "어느 규칙이 바뀌는지" 가 그대로 보인다.
#
# 주의: AWS 는 SG 를 만들 때 "모든 아웃바운드 허용" 기본 규칙을 넣지만, Terraform 의 aws_security_group 은
#   생성 직후 그 기본 규칙을 지운다. 그래서 아웃바운드도 필요한 것을 명시해야 한다(rds 는 아웃바운드 없음).
# ---------------------------------------------------------------------------

# < alb > ALB 자체에 붙는 SG. 인터넷에서 HTTPS·HTTP 를 받고, Pod 포트로만 나간다.
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb"
  description = "ALB: internet 443/80 in, app ports to node out"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# 443: Raspberry Pi 와 브라우저의 HTTPS. ACM 인증서는 ALB 가 종단한다.
# 소스는 var.alb_ingress_cidrs(기본값 없음 — terraform.tfvars 에 명시해야 한다). 관리자 UI 검증 기간에는 사용자 공인 IP /32 로 좁힌다(변수 설명 참고).
# 원래 단일 리소스였던 것을 CIDR 별 for_each 로 바꿨다. moved 블록은 이전 단일 리소스를 "0.0.0.0/0" 인스턴스로 이어 붙인다(이미 제한 CIDR 로 apply 된 state 에는 영향 없음).
# create_before_destroy: CIDR 를 바꿀 때 새 규칙을 먼저 만든 뒤 옛 규칙을 지워 접속이 끊기는 틈을 없앤다.
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = each.value == "0.0.0.0/0" ? "HTTPS from internet" : "HTTPS from ${each.value}" # 기본값의 기존 설명을 그대로 둔다(plan 변화 0)
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  lifecycle {
    create_before_destroy = true
  }
}

# 80: HTTP → HTTPS 리다이렉트 용(Ingress 의 ssl-redirect). 리다이렉트는 ALB 가 하므로 Pod 까지 가지 않는다.
# https:// 로 직접 접속하면 필요 없다. 제한 기간에도 같은 CIDR 로만 열어 주소창에 http:// 로 쳐도 리다이렉트 되게 한다(응답은 301 뿐이라 위험이 작다).
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = each.value == "0.0.0.0/0" ? "HTTP from internet (redirect to HTTPS)" : "HTTP from ${each.value} (redirect to HTTPS)"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80

  lifecycle {
    create_before_destroy = true
  }
}

# 단일 리소스 → for_each 전환: 기존 규칙을 "0.0.0.0/0" 인스턴스로 이어 붙인다(state 이동만, AWS 변경 없음).
moved {
  from = aws_vpc_security_group_ingress_rule.alb_https
  to   = aws_vpc_security_group_ingress_rule.alb_https["0.0.0.0/0"]
}

moved {
  from = aws_vpc_security_group_ingress_rule.alb_http
  to   = aws_vpc_security_group_ingress_rule.alb_http["0.0.0.0/0"]
}

# alb → node, 포트마다 규칙 하나. for_each 로 backend(5000), frontend(8080).
# 목적지를 CIDR 이 아니라 node SG 로 적는다(referenced_security_group_id).
resource "aws_vpc_security_group_egress_rule" "alb_to_node" {
  for_each = var.app_ports

  security_group_id            = aws_security_group.alb.id
  description                  = "to ${each.key} pods"
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}

# < node > EKS 워커 노드(와 그 위의 Pod)에 붙는 추가 SG.
# 노드 ↔ 컨트롤 플레인, 노드 ↔ 노드 통신은 EKS 가 따로 만드는 "클러스터 SG" 가 담당한다. 여기선 ALB·RDS 와의 경계만.
resource "aws_security_group" "node" {
  name        = "${var.project_name}-node"
  description = "EKS nodes: app ports from alb in, all out"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-node"
  }
}

# alb → node 와 짝이 되는 수신 규칙. SG 는 양쪽 다 열려야 통한다(alb 의 egress + node 의 ingress).
resource "aws_vpc_security_group_ingress_rule" "node_from_alb" {
  for_each = var.app_ports

  security_group_id            = aws_security_group.node.id
  description                  = "${each.key} from alb"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}

# 노드 아웃바운드는 전부 허용. 필요한 목적지가 많고 IP 가 고정되지 않는다:
#   ECR API·STS·CloudWatch(NAT 경유), S3(Endpoint), RDS(5432), EKS API 엔드포인트, 이미지 레지스트리, OS 패키지.
# ip_protocol "-1" = 모든 프로토콜(이때 from_port/to_port 는 적지 않는다).
resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  description       = "all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# < rds > RDS 인스턴스에 붙는 SG. node 에서 오는 5432 만 받고, 아웃바운드는 없다(RDS 가 밖으로 나갈 일이 없다).
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds"
  description = "RDS PostgreSQL: 5432 from node only"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-rds"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_node" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from node"
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
