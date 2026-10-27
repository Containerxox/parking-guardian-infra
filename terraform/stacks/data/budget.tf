# ---------------------------------------------------------------------------
# AWS Budgets: 월 비용이 정한 금액에 도달하면 이메일을 보낸다. 무료(예산 2개까지).
# data 스택의 첫 리소스로 두는 이유: 뒤에 EKS·NAT·RDS 처럼 시간당 비용이 붙는 것을 만들기 전에 경보를 먼저 세운다
# (architecture.md 5절 "Budgets·Anomaly Detection 을 첫 리소스로").
#
# Budgets 는 "글로벌" 서비스다. 리전 개념이 없고 계정 단위다. provider 의 ap-northeast-2 로 호출해도 된다.
# 자동 조치(리소스 중지·삭제 액션)는 붙이지 않는다(결정 12). 경보가 오면 Cost Explorer 에서 원인을 보는 것이 운영 절차.
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name = "${var.project_name}-monthly"

  # COST: 금액 기준. (USAGE, RI_UTILIZATION 등도 있다)
  budget_type = "COST"

  # 예산 금액. 문자열이어야 해서 number 변수를 tostring 으로 바꾼다.
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"

  # 매달 1일 0시에 누적이 0 으로 돌아간다. time_period_start 를 생략하면 "이번 달 1일" 부터.
  time_unit = "MONTHLY"

  # 비용 집계 방식. 기본값은 크레딧·환불을 포함해 "청구서에 찍히는 금액" 기준이다.
  # Free Plan 크레딧이 있으면 실제 결제액은 0 이어도 경보는 사용량 기준으로 받고 싶으므로 크레딧을 "제외" 한다.
  # (크레딧을 포함하면 크레딧이 비용을 상쇄해 $50 경보가 안 올 수 있다.)
  cost_types {
    include_credit = false
    include_refund = false
    # 나머지(include_tax, include_support 등)는 기본값 true 유지.
  }

  # 임계값마다 알림 블록 하나. dynamic 블록은 리스트를 돌면서 같은 모양의 블록을 반복 생성한다.
  # for_each 리소스와 비슷하지만 "리소스 안의 중첩 블록" 용이다.
  dynamic "notification" {
    for_each = var.budget_alert_thresholds

    content {
      # ACTUAL: 실제 누적 비용. (FORECASTED 는 월말 예측값 기준. 설계는 실제 기준)
      notification_type = "ACTUAL"

      # 실제 비용 > threshold 일 때. ABSOLUTE_VALUE = 달러 절대값 (PERCENTAGE 는 예산 대비 %).
      comparison_operator = "GREATER_THAN"
      threshold           = notification.value
      threshold_type      = "ABSOLUTE_VALUE"

      # SNS 토픽 없이 Budgets 가 직접 이메일을 보낸다(결정 12). 구독 확인 메일은 없다. 즉시 활성.
      subscriber_email_addresses = var.budget_alert_emails
    }
  }
}
