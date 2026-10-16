#!/usr/bin/env bash
# 40-scheduler - 원래부터 gcloud 단계. 멱등(create/update) 처리만 추가.

source "$(dirname "$0")/00-env.sh"

URI="https://workflowexecutions.googleapis.com/v1/projects/${EDGE_PROJECT}/locations/${REGION}/workflows/${WORKFLOW_NAME}/executions"

COMMON_ARGS=(
  --project="${EDGE_PROJECT}"
  --location="${REGION}"
  --schedule="${SCHEDULE_CRON}"
  --time-zone="${SCHEDULE_TZ}"
  --uri="${URI}"
  --http-method=POST
  --oauth-service-account-email="${SA_WORKFLOW}"
  --oauth-token-scope="https://www.googleapis.com/auth/cloud-platform"
  --headers="Content-Type=application/json"
  --message-body='{"argument":"{}"}'
)

log "Scheduler Job: ${SCHEDULER_JOB}"
if gcloud scheduler jobs describe "${SCHEDULER_JOB}" \
     --project="${EDGE_PROJECT}" --location="${REGION}" >/dev/null 2>&1; then
  log "이미 존재 -> update"
  gcloud scheduler jobs update http "${SCHEDULER_JOB}" "${COMMON_ARGS[@]}"
else
  gcloud scheduler jobs create http "${SCHEDULER_JOB}" "${COMMON_ARGS[@]}"
fi

log "40-scheduler 완료. 즉시 테스트: gcloud scheduler jobs run ${SCHEDULER_JOB} --location=${REGION} --project=${EDGE_PROJECT}"
