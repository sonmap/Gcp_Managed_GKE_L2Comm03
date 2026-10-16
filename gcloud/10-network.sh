#!/usr/bin/env bash
# terraform/10-network/main.tf 의 gcloud 등가 구현
#
# ** 이 스크립트는 Owner 계정(admin@sonmap.net)으로 실행합니다. **
#
# Shared VPC 연결, Host 프로젝트 Subnet 생성, Subnet/Project 레벨 IAM 부여는
# 모두 네트워크 관리 영역이므로 Owner 가 수행합니다.
# 조직 수준 compute.xpnAdmin 이 필요한 작업(Shared VPC 서비스 프로젝트 연결)도
# 여기에 포함되므로 배포 주체 계정으로는 수행하지 않습니다.
#
#   gcloud config set account admin@sonmap.net
#   ./gcloud/10-network.sh
#   gcloud config set account cho@sonmap.net     # 이후 단계

source "$(dirname "$0")/00-env.sh"

# 네트워크 관리 영역 -> Owner 로 실행
require_account "${OWNER_USER}"

###############################################################################
# 0) 사전 확인 - CIDR 중복 검사 (README 8 항목)
###############################################################################
log "기존 Subnet 목록 확인 (중복 CIDR 검토용)"
gcloud compute networks subnets list \
  --project="${HOST_PROJECT}" \
  --regions="${REGION}" \
  --format="table(name, ipCidrRange, secondaryIpRanges[].ipCidrRange)"

echo
echo "아래 대역이 위 목록 및 On-Prem/VPN 과 겹치지 않는지 확인하십시오:"
echo "  Node    ${NODE_CIDR}"
echo "  Pod     ${POD_CIDR}"
echo "  Master  ${CONTROL_PLANE_CIDR}"
read -r -p "계속하려면 Enter, 중단하려면 Ctrl+C: " _

###############################################################################
# 1) API  (google_project_service)
###############################################################################
gcloud services enable secretmanager.googleapis.com \
  --project="${EDGE_PROJECT}"

###############################################################################
# 2) Cloud Build P4SA / 배포 SA 권한  (google_project_iam_member)
###############################################################################
bind_project "${EDGE_PROJECT}" "serviceAccount:${CLOUDBUILD_P4SA}" roles/secretmanager.admin

# terraform 의 inframgr_cloudbuild_editor -> 실제 실행 주체(ADMIN_USER)로 대체.
# 00-bootstrap.sh 에서 이미 부여되므로 중복이지만, 10 단계만 단독 실행하는 경우를 위해 유지합니다.
bind_project "${EDGE_PROJECT}" "user:${ADMIN_USER}" roles/cloudbuild.builds.editor

###############################################################################
# 3) Shared VPC 서비스 프로젝트 연결
#    (google_compute_shared_vpc_service_project)
###############################################################################
log "Shared VPC 서비스 프로젝트 연결"
if gcloud compute shared-vpc associated-projects list "${HOST_PROJECT}" \
     --format='value(id)' 2>/dev/null | grep -qx "${EDGE_PROJECT}"; then
  log "SKIP (이미 연결됨): ${EDGE_PROJECT}"
else
  gcloud compute shared-vpc associated-projects add "${EDGE_PROJECT}" \
    --host-project="${HOST_PROJECT}"
fi

###############################################################################
# 4) GKE Subnet + Pod Secondary Range
#    (google_compute_subnetwork)
#    - Service Secondary Range 는 생성하지 않음 (Autopilot managed 사용)
###############################################################################
log "Subnet 생성: ${SUBNET_NAME}"
if gcloud compute networks subnets describe "${SUBNET_NAME}" \
     --project="${HOST_PROJECT}" --region="${REGION}" >/dev/null 2>&1; then
  log "SKIP (이미 존재): ${SUBNET_NAME}"
else
  gcloud compute networks subnets create "${SUBNET_NAME}" \
    --project="${HOST_PROJECT}" \
    --region="${REGION}" \
    --network="${NETWORK_NAME}" \
    --range="${NODE_CIDR}" \
    --secondary-range="${POD_RANGE_NAME}=${POD_CIDR}" \
    --enable-private-ip-google-access
fi

###############################################################################
# 5) Subnet 레벨 IAM  (google_compute_subnetwork_iam_member)
###############################################################################
subnet_bind() {  # subnet_bind <member>
  log "Subnet IAM :: ${1} -> roles/compute.networkUser"
  gcloud compute networks subnets add-iam-policy-binding "${SUBNET_NAME}" \
    --project="${HOST_PROJECT}" \
    --region="${REGION}" \
    --member="${1}" \
    --role=roles/compute.networkUser \
    --quiet >/dev/null
}

for MEMBER in "${GKE_SERVICE_AGENT}" "${CLOUD_SERVICES_SA}"; do
  subnet_bind "serviceAccount:${MEMBER}"
done

# 배포 주체가 30-platform.sh 에서 이 Subnet 을 지정해 GKE 를 만들려면
# Subnet 레벨 networkUser 가 필요합니다. Host 프로젝트 전체 권한을 주지 않고
# 이 Subnet 에만 한정해 부여합니다.
subnet_bind "user:${ADMIN_USER}"
subnet_bind "serviceAccount:${VM_SA}"

###############################################################################
# 6) Host project 레벨 GKE Service Agent 권한
#    (google_project_iam_member)
###############################################################################
bind_project "${HOST_PROJECT}" "serviceAccount:${GKE_SERVICE_AGENT}" \
  roles/container.hostServiceAgentUser \
  roles/compute.securityAdmin

###############################################################################
# 7) 확인 (terraform output 대체)
###############################################################################
log "결과 확인"
gcloud compute networks subnets describe "${SUBNET_NAME}" \
  --project="${HOST_PROJECT}" --region="${REGION}" \
  --format="yaml(name, ipCidrRange, secondaryIpRanges, privateIpGoogleAccess)"

log "10-network 완료"

cat <<EOF

=== 다음 단계 ===
네트워크 관리 영역은 여기까지입니다. 배포 주체로 전환한 뒤 진행하십시오.

  gcloud config set account ${ADMIN_USER}
  ./gcloud/20-source-connection.sh
EOF
