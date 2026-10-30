#!/usr/bin/env python3
"""Phase 1 의 Terraform 변경이 "의도한 만큼만" 일어나는지 plan 으로 확인한다. apply 는 하지 않는다.

    terraform -chdir=terraform/stacks/data    plan -input=false -lock=false -out=data.plan
    terraform -chdir=terraform/stacks/cluster plan -input=false -lock=false -out=cluster.plan
    terraform -chdir=terraform/stacks/data    show -json data.plan    > data.plan.json
    terraform -chdir=terraform/stacks/cluster show -json cluster.plan > cluster.plan.json
    python scripts/check-phase1-plan.py --data data.plan.json --cluster cluster.plan.json \\
        [--addon-schema cloudwatch-schema.json]

확인하는 것 (설계 9.1, 3.12, 4.6):
  data     inference 용 ECR 리포지토리와 lifecycle 정책이 새로 생기고, GitHub Actions 푸시 권한이 자동으로 따라 늘어난다.
           그 밖의 변경(삭제·교체 포함)은 없다.
  cluster  inference 전용 Pod Identity 역할(모델 읽기만)과 연결이 생기고, backend 역할에서 모델 권한이 빠진다.
           CloudWatch Observability add-on 은 버전이 고정되고 nodeExporter / kubeStateMetrics 가 꺼진다.
           그 밖의 새 리소스는 없다 (기준: 변경 전 plan 이 31개 생성).

plan JSON 에는 계정 ID 와 ARN 이 들어 있으므로 저장소에 커밋하지 않는다 (*.tfplan 은 .gitignore, JSON 은 임시 폴더에).
"""
from __future__ import annotations

import argparse
import json
import sys

PROJECT = "parking-guardian"
APP_NAMESPACE = "parking-guardian"
CLUSTER_BASELINE_CREATES = 31          # Phase 1 변경 전 cluster 스택 plan 의 생성 수 (2026-10-30 확인, 10-28 destroy 31개와 같다)
CLUSTER_NEW_RESOURCES = {              # Phase 1 이 더하는 것: inference 역할, 인라인 정책, Pod Identity 연결
    "aws_iam_role.inference",
    "aws_iam_role_policy.inference_models",
    "aws_eks_pod_identity_association.inference",
}
EXPECTED_ADDON_VERSION = "v6.7.0-eksbuild.1"   # 10-27/28 에 실제로 돌며 요청 합(700m/노드 2대)을 잰 버전

failures: list[str] = []


def check(ok: bool, message: str) -> None:
    print(("  ok    " if ok else "  FAIL  ") + message)
    if not ok:
        failures.append(message)


def by_address(plan: dict) -> dict[str, dict]:
    """관리 리소스만. 데이터 소스(예: IAM 정책 문서)의 `read` 는 AWS 를 바꾸는 동작이 아니다."""
    return {rc["address"]: rc for rc in plan.get("resource_changes", []) if rc.get("mode", "managed") == "managed"}


def actions(rc: dict) -> tuple:
    return tuple(rc["change"]["actions"])


def policy_statements(rc: dict) -> list[dict]:
    doc = json.loads(rc["change"]["after"]["policy"])
    statements = doc["Statement"]
    return statements if isinstance(statements, list) else [statements]


def flatten(value) -> list:
    return value if isinstance(value, list) else [value]


def check_data(plan: dict) -> None:
    print("\n[data] ECR")
    rcs = by_address(plan)
    changed = {a: actions(rc) for a, rc in rcs.items() if actions(rc) != ("no-op",)}
    creates = {a for a, act in changed.items() if act == ("create",)}
    updates = {a for a, act in changed.items() if act == ("update",)}
    others = {a: act for a, act in changed.items() if act not in (("create",), ("update",))}

    check(creates == {'aws_ecr_repository.this["inference"]', 'aws_ecr_lifecycle_policy.this["inference"]'},
          f"새로 생기는 것은 inference 리포지토리와 lifecycle 정책뿐이다 (실제: {sorted(creates)})")
    check(updates == {"aws_iam_role_policy.github_actions_ecr"},
          f"기존 리소스의 변경은 GitHub Actions ECR 푸시 정책 하나뿐이다 (실제: {sorted(updates)})")
    check(not others, f"삭제·교체가 없다 (실제: {others})")

    repo = rcs.get('aws_ecr_repository.this["inference"]')
    if repo:
        after = repo["change"]["after"]
        check(after["name"] == f"{PROJECT}/inference", f"리포지토리 이름 {PROJECT}/inference (실제: {after['name']})")
        check(after["image_tag_mutability"] == "IMMUTABLE", "태그 불변(IMMUTABLE): 같은 태그로 덮어쓸 수 없다")
        check(after["image_scanning_configuration"][0]["scan_on_push"] is True, "푸시 때 취약점 스캔")
    for existing in ("backend", "frontend"):
        check(actions(rcs[f'aws_ecr_repository.this["{existing}"]']) == ("no-op",), f"기존 {existing} 리포지토리는 그대로다")


def check_cluster(plan: dict, schema: dict | None) -> None:
    print("\n[cluster] IAM / Pod Identity / add-on")
    rcs = by_address(plan)
    creates = {a for a, rc in rcs.items() if actions(rc) == ("create",)}
    others = {a: actions(rc) for a, rc in rcs.items() if actions(rc) != ("create",)}
    check(not others, f"cluster 스택은 처음부터 만드는 plan 이라 전부 create 다 (실제 다른 동작: {others})")
    check(len(creates) == CLUSTER_BASELINE_CREATES + len(CLUSTER_NEW_RESOURCES),
          f"생성 수 = 기준 {CLUSTER_BASELINE_CREATES} + 새 {len(CLUSTER_NEW_RESOURCES)} (실제: {len(creates)})")
    check(CLUSTER_NEW_RESOURCES <= creates, f"inference 역할·정책·연결이 있다 (없는 것: {sorted(CLUSTER_NEW_RESOURCES - creates)})")

    # --- inference: 모델 읽기 외에는 아무것도 못 한다 -------------------------------------------------------
    if CLUSTER_NEW_RESOURCES <= creates:
        allowed_actions = {"s3:ListBucket", "s3:GetObject"}
        statements = policy_statements(rcs["aws_iam_role_policy.inference_models"])
        used = {act for st in statements for act in flatten(st["Action"])}
        check(used == allowed_actions, f"inference 정책의 동작은 {sorted(allowed_actions)} 뿐이다 (실제: {sorted(used)})")
        check(all(st["Effect"] == "Allow" for st in statements), "inference 정책에 Deny 가 아닌 Allow 만 있다(권한 추가가 아님을 확인용)")
        resources = {r for st in statements for r in flatten(st["Resource"])}
        check(all("models" in r for r in resources), f"inference 정책의 대상은 모델 버킷뿐이다 (실제: {sorted(resources)})")
        check(not any(("photos" in r) for r in resources), "inference 정책에 사진 버킷이 없다")
        forbidden = ("secretsmanager", "rds", "kms", "ssm", "sts", "iam", "ecr", "logs", "ec2")
        check(not any(act.split(":")[0] in forbidden for act in used), "Secrets Manager / RDS / KMS / IAM 관련 동작이 없다")

        assoc = rcs["aws_eks_pod_identity_association.inference"]["change"]["after"]
        check(assoc["namespace"] == APP_NAMESPACE and assoc["service_account"] == "inference",
              f"Pod Identity 연결 = {APP_NAMESPACE}/inference (실제: {assoc['namespace']}/{assoc['service_account']})")
        check(not any(rc["type"] == "aws_iam_role_policy_attachment" and "inference" in rc["address"] for rc in rcs.values()),
              "inference 역할에 AWS 관리형 정책 attachment 가 없다")
        role = rcs["aws_iam_role.inference"]["change"]["after"]
        trust = json.loads(role["assume_role_policy"])["Statement"][0]
        check(trust["Principal"]["Service"] == "pods.eks.amazonaws.com", "신뢰 정책 주체는 pods.eks.amazonaws.com (backend 와 같은 방식)")

    # --- backend: 사진만 ---------------------------------------------------------------------------------
    backend = rcs.get("aws_iam_role_policy.backend_s3")
    if backend:
        statements = policy_statements(backend)
        used = {act for st in statements for act in flatten(st["Action"])}
        resources = {r for st in statements for r in flatten(st["Resource"])}
        check(used == {"s3:PutObject", "s3:GetObject"}, f"backend 정책의 동작은 사진 Put/Get 뿐이다 (실제: {sorted(used)})")
        check(not any("models" in r for r in resources), f"backend 정책에서 모델 버킷이 빠졌다 (실제 대상: {sorted(resources)})")
        check(all("photos" in r for r in resources), "backend 정책의 대상은 사진 버킷뿐이다")

    # --- CloudWatch Observability: 버전 고정 + 중복 구성 요소 끄기 -----------------------------------------
    addon = rcs["aws_eks_addon.cloudwatch_observability"]["change"]["after"]
    check(addon.get("addon_version") == EXPECTED_ADDON_VERSION,
          f"CloudWatch add-on 버전이 고정되어 있다: {EXPECTED_ADDON_VERSION} (실제: {addon.get('addon_version')})")
    values = json.loads(addon["configuration_values"])
    check(values.get("nodeExporter", {}).get("enabled") is False, "nodeExporter 를 명시적으로 끈다 (kube-prometheus-stack 이 이미 노드 지표를 낸다)")
    check(values.get("kubeStateMetrics", {}).get("enabled") is False, "kubeStateMetrics 를 명시적으로 끈다 (monitoring 스택에 이미 있다)")
    check(values.get("applicationSignals", {}).get("enabled") is False, "기존 설정(applicationSignals 끔)이 유지된다")
    check(values.get("manager", {}).get("applicationSignals", {}).get("autoMonitor", {}).get("monitorAllServices") is False,
          "기존 설정(monitorAllServices 끔)이 유지된다")
    if schema:
        problems = validate_against_schema(values, schema)
        check(not problems, f"configuration_values 가 고정 버전의 공개 스키마와 맞는다 (문제: {problems})")


def validate_against_schema(value, schema, path="") -> list[str]:
    """스키마에 없는 키와 타입이 다른 값을 찾는다 (jsonschema 패키지 없이, 이 설정에 필요한 만큼만)."""
    problems: list[str] = []
    expected = schema.get("type")
    if expected == "boolean" and not isinstance(value, bool):
        problems.append(f"{path}: boolean 이어야 한다")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key, sub in value.items():
            if key not in props:
                problems.append(f"{path}/{key}: 스키마에 없는 키")
            else:
                problems += validate_against_schema(sub, props[key], f"{path}/{key}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", required=True, help="data 스택 `terraform show -json` 결과")
    parser.add_argument("--cluster", required=True, help="cluster 스택 `terraform show -json` 결과")
    parser.add_argument("--addon-schema", help="aws eks describe-addon-configuration 의 configurationSchema JSON (선택)")
    args = parser.parse_args()
    load = lambda path: json.load(open(path, encoding="utf-8"))
    check_data(load(args.data))
    check_cluster(load(args.cluster), load(args.addon_schema) if args.addon_schema else None)
    print(f"\n{'실패 ' + str(len(failures)) + '건' if failures else '모두 통과'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
