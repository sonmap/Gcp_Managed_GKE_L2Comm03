#!/usr/bin/env bash
# 20-source-connection - 원래부터 gcloud 단계였으므로 그대로 유지 (멱등 처리만 추가)

source "$(dirname "$0")/00-env.sh"

# 자원 생성/운영 단계 -> 배포 주체로 실행 (Owner 아님)
require_account "${ADMIN_USER}"

log "Cloud Build Connection 확인"
gcloud builds connections list \
  --project="${EDGE_PROJECT}" --region="${REGION}" \
  --format="table(name, githubConfig.appInstallationId, installationState.stage)"

log "Repository 연결: ${CB_REPO}"
if gcloud builds repositories describe "${CB_REPO}" \
     --connection="${CB_CONNECTION}" \
     --project="${EDGE_PROJECT}" --region="${REGION}" >/dev/null 2>&1; then
  log "SKIP (이미 연결됨): ${CB_REPO}"
else
  gcloud builds repositories create "${CB_REPO}" \
    --project="${EDGE_PROJECT}" \
    --region="${REGION}" \
    --connection="${CB_CONNECTION}" \
    --remote-uri="${CB_REMOTE_URI}"
fi

gcloud builds repositories list \
  --connection="${CB_CONNECTION}" \
  --project="${EDGE_PROJECT}" --region="${REGION}" \
  --format="table(name, remoteUri)"

log "20-source-connection 완료"
