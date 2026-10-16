#!/usr/bin/env bash
# terraform/00-bootstrap/main.tf 의 gcloud 등가 구현
#
# 주의: gcloud 전환 시 Infrastructure Manager(config.googleapis.com) 는
#       사용하지 않으므로 sa-l2comm-inframgr 관련 블록은 선택사항입니다.
#       필요 없으면 CREATE_INFRAMGR=false 로 두세요.

source "$(dirname "$0")/00-env.sh"

CREATE_INFRAMGR="${CREATE_INFRAMGR:-false}"   # Infra Manager 병행 운영 시에만 true
CREATE_TFSTATE_BUCKET="${CREATE_TFSTATE_BUCKET:-false}"  # gcloud 전용이면 불필요

###############################################################################
# 1) API 활성화  (google_project_service)
###############################################################################
EDGE_APIS=(
  artifactregistry.googleapis.com
  bigquery.googleapis.com
  cloudbuild.googleapis.com
  cloudresourcemanager.googleapis.com
  cloudscheduler.googleapis.com
  compute.googleapis.com
  container.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  logging.googleapis.com
  monitoring.googleapis.com
  secretmanager.googleapis.com
  serviceusage.googleapis.com
  storage.googleapis.com
  workflows.googleapis.com
  workflowexecutions.googleapis.com
)
# Infra Manager 를 쓰지 않으면 config.googleapis.com 은 제외
[[ "${CREATE_INFRAMGR}" == "true" ]] && EDGE_APIS+=(config.googleapis.com)

HOST_APIS=(
  compute.googleapis.com
  container.googleapis.com
  serviceusage.googleapis.com
)

log "Edge project API 활성화"
gcloud services enable "${EDGE_APIS[@]}" --project="${EDGE_PROJECT}"

log "Host project API 활성화"
gcloud services enable "${HOST_APIS[@]}" --project="${HOST_PROJECT}"

###############################################################################
# 2) Terraform state 버킷  (google_storage_bucket)
#    -> gcloud 전용 운영이면 불필요. 산출물/로그 보관용으로만 쓰려면 true.
###############################################################################
if [[ "${CREATE_TFSTATE_BUCKET}" == "true" ]]; then
  log "State 버킷 생성"
  ok_if_exists gcloud storage buckets create "gs://${TFSTATE_BUCKET}" \
    --project="${EDGE_PROJECT}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
  # terraform 의 versioning { enabled = true } 는 별도 update 명령
  gcloud storage buckets update "gs://${TFSTATE_BUCKET}" --versioning
fi

###############################################################################
# 3) 서비스 계정  (google_service_account)
###############################################################################
log "sa-l2comm-tf-admin 생성"
ok_if_exists gcloud iam service-accounts create sa-l2comm-tf-admin \
  --project="${EDGE_PROJECT}" \
  --display-name="L2Comm delegated administrator"

if [[ "${CREATE_INFRAMGR}" == "true" ]]; then
  ok_if_exists gcloud iam service-accounts create sa-l2comm-inframgr \
    --project="${EDGE_PROJECT}" \
    --display-name="L2Comm Infrastructure Manager execution SA"
fi

###############################################################################
# 4) 배포 SA 권한  (google_project_iam_member)
###############################################################################
TF_ADMIN_MEMBER="serviceAccount:${SA_TFADMIN}"

bind_project "${EDGE_PROJECT}" "${TF_ADMIN_MEMBER}" \
  roles/artifactregistry.admin \
  roles/cloudbuild.builds.editor \
  roles/compute.viewer \
  roles/container.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/resourcemanager.projectIamAdmin \
  roles/serviceusage.serviceUsageAdmin

bind_project "${HOST_PROJECT}" "${TF_ADMIN_MEMBER}" \
  roles/compute.networkAdmin \
  roles/compute.securityAdmin \
  roles/resourcemanager.projectIamAdmin \
  roles/serviceusage.serviceUsageAdmin

bind_project "${DATA_PROJECT}" "${TF_ADMIN_MEMBER}" \
  roles/bigquery.admin

if [[ "${CREATE_TFSTATE_BUCKET}" == "true" ]]; then
  gcloud storage buckets add-iam-policy-binding "gs://${TFSTATE_BUCKET}" \
    --member="${TF_ADMIN_MEMBER}" --role=roles/storage.objectAdmin --quiet >/dev/null
  gcloud storage buckets add-iam-policy-binding "gs://${TFSTATE_BUCKET}" \
    --member="user:${ADMIN_USER}" --role=roles/storage.objectAdmin --quiet >/dev/null
fi

###############################################################################
# 5) 가장(impersonation) 권한  (google_service_account_iam_member)
###############################################################################
bind_sa "${SA_TFADMIN}" "serviceAccount:${VM_SA}"   roles/iam.serviceAccountTokenCreator
bind_sa "${SA_TFADMIN}" "user:${ADMIN_USER}"        roles/iam.serviceAccountTokenCreator

###############################################################################
# 6) Infra Manager SA (선택)
###############################################################################
if [[ "${CREATE_INFRAMGR}" == "true" ]]; then
  INFRAMGR_MEMBER="serviceAccount:sa-l2comm-inframgr@${EDGE_PROJECT}.iam.gserviceaccount.com"
  bind_project "${EDGE_PROJECT}" "${INFRAMGR_MEMBER}" \
    roles/artifactregistry.admin \
    roles/cloudbuild.builds.editor \
    roles/compute.viewer \
    roles/config.agent \
    roles/container.admin \
    roles/iam.serviceAccountAdmin \
    roles/iam.serviceAccountUser \
    roles/logging.viewer \
    roles/resourcemanager.projectIamAdmin \
    roles/workflows.admin
  bind_project "${HOST_PROJECT}" "${INFRAMGR_MEMBER}" roles/compute.networkUser
  bind_project "${DATA_PROJECT}" "${INFRAMGR_MEMBER}" roles/bigquery.admin
  bind_sa "sa-l2comm-inframgr@${EDGE_PROJECT}.iam.gserviceaccount.com" \
    "serviceAccount:${VM_SA}" roles/iam.serviceAccountUser
  bind_sa "sa-l2comm-inframgr@${EDGE_PROJECT}.iam.gserviceaccount.com" \
    "user:${ADMIN_USER}" roles/iam.serviceAccountUser
  bind_project "${EDGE_PROJECT}" "serviceAccount:${VM_SA}" roles/config.admin
fi

log "00-bootstrap 완료"
