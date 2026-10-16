#!/usr/bin/env bash
# terraform/00-bootstrap/main.tf 의 gcloud 등가 구현
#
# ** 이 스크립트만 Owner 계정(admin@sonmap.net)으로 실행합니다. **
#
# 여기서 하는 일은 API 활성화와 IAM 부여뿐이며, Owner 권한이 필요한 작업은
# 이 단계가 전부입니다. 실제 자원 생성(10 단계 이후)은 여기서 Role 을 받은
# 배포 주체(cho@sonmap.net)로 수행합니다.
#
#   gcloud auth login admin@sonmap.net
#   gcloud config set account admin@sonmap.net
#   ./gcloud/00-bootstrap.sh
#   gcloud config set account cho@sonmap.net     # 이후 단계
#
# 주의: gcloud 전환 시 Infrastructure Manager(config.googleapis.com) 는
#       사용하지 않으므로 sa-l2comm-inframgr 관련 블록은 선택사항입니다.
#       필요 없으면 CREATE_INFRAMGR=false 로 두세요.

source "$(dirname "$0")/00-env.sh"

# 권한 부여 단계 -> Owner 로 실행
require_account "${OWNER_USER}"

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
  compute.googleapis.com
  container.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  logging.googleapis.com
  monitoring.googleapis.com
  secretmanager.googleapis.com
  serviceusage.googleapis.com
  storage.googleapis.com
)
# Workflows / Cloud Scheduler 는 L2Comm03 런타임 경로에서 사용하지 않습니다.
# (run-gke.sh -> client_gke -> GKE Job 직접 실행)
# Infra Manager 를 쓰지 않으면 config.googleapis.com 은 제외
[[ "${CREATE_INFRAMGR}" == "true" ]] && EDGE_APIS+=(config.googleapis.com)

HOST_APIS=(
  artifactregistry.googleapis.com   # AR 이 Host 프로젝트에 있음
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
#
#    sa-l2comm-tf-admin 은 L2Comm03 에서 삭제되었습니다.
#    Terraform 위임 실행이 없어졌으므로 배포는 ADMIN_USER 가 직접 수행합니다.
#    런타임용 통합 SA(sa-l2comm-gke)는 30-platform.sh 에서 생성합니다.
###############################################################################
if [[ "${CREATE_INFRAMGR}" == "true" ]]; then
  ok_if_exists gcloud iam service-accounts create sa-l2comm-inframgr \
    --project="${EDGE_PROJECT}" \
    --display-name="L2Comm Infrastructure Manager execution SA"
fi

###############################################################################
# 4) 배포 주체 권한  (google_project_iam_member)
#
#    L2Comm02 에서는 sa-l2comm-tf-admin 에 부여하고 ADMIN_USER 가 이를 가장했으나,
#    L2Comm03 은 해당 SA 를 삭제했으므로 동일한 Role 집합을 ADMIN_USER 에게
#    직접 부여합니다. (Role 구성 자체는 L2Comm02 와 동일)
###############################################################################
DEPLOYER_MEMBER="user:${ADMIN_USER}"

bind_project "${EDGE_PROJECT}" "${DEPLOYER_MEMBER}" \
  roles/cloudbuild.builds.editor \
  roles/compute.viewer \
  roles/container.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/resourcemanager.projectIamAdmin \
  roles/serviceusage.serviceUsageAdmin

# Host 프로젝트에는 Artifact Registry 운영에 필요한 최소 권한만 부여합니다.
# 네트워크 관리(compute.networkAdmin / securityAdmin)는 Owner 영역이므로
# 배포 주체에게 주지 않습니다. GKE 생성에 필요한 Subnet 접근은
# 10-network.sh 가 해당 Subnet 한정으로 compute.networkUser 를 부여합니다.
bind_project "${HOST_PROJECT}" "${DEPLOYER_MEMBER}" \
  roles/artifactregistry.admin \
  roles/serviceusage.serviceUsageAdmin

bind_project "${DATA_PROJECT}" "${DEPLOYER_MEMBER}" \
  roles/bigquery.admin

# VM 에서 스크립트를 실행하는 경우 VM 기본 SA 에도 동일 Role 이 필요합니다.
if [[ "${GRANT_VM_DEPLOYER:-false}" == "true" ]]; then
  bind_project "${EDGE_PROJECT}" "serviceAccount:${VM_SA}" \
    roles/cloudbuild.builds.editor \
    roles/compute.viewer \
    roles/container.admin \
    roles/iam.serviceAccountAdmin \
    roles/iam.serviceAccountUser \
    roles/resourcemanager.projectIamAdmin \
    roles/serviceusage.serviceUsageAdmin
  bind_project "${HOST_PROJECT}" "serviceAccount:${VM_SA}" \
    roles/artifactregistry.admin
  bind_project "${DATA_PROJECT}" "serviceAccount:${VM_SA}" roles/bigquery.admin
fi

if [[ "${CREATE_TFSTATE_BUCKET}" == "true" ]]; then
  gcloud storage buckets add-iam-policy-binding "gs://${TFSTATE_BUCKET}" \
    --member="${DEPLOYER_MEMBER}" --role=roles/storage.objectAdmin --quiet >/dev/null
fi

###############################################################################
# 5) Infra Manager SA (선택)
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

cat <<EOF

=== 다음 단계 ===
네트워크 구성(10-network.sh)도 관리 영역이므로 Owner 계정으로 이어서 실행합니다.

  ./gcloud/10-network.sh

그 이후(20 단계부터) 배포 주체로 전환합니다.

  gcloud config set account ${ADMIN_USER}
  ./gcloud/20-source-connection.sh

부여된 Role 확인:
  gcloud projects get-iam-policy ${EDGE_PROJECT} \\
    --flatten="bindings[].members" \\
    --filter="bindings.members:${ADMIN_USER}" \\
    --format="value(bindings.role)"
EOF
