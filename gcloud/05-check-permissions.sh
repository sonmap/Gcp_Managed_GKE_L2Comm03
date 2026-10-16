#!/usr/bin/env bash
# 배포 주체(cho@sonmap.net)가 20/30 단계를 수행할 권한을 갖추었는지 사전 점검합니다.
#
# 실행 시점: 00-bootstrap.sh / 10-network.sh (Owner) 완료 후,
#            20-source-connection.sh 실행 전.
# 실행 계정: 배포 주체. test-iam-permissions 는 "호출자 자신"의 권한을 반환하므로
#            반드시 점검 대상 계정으로 실행해야 의미가 있습니다.
#
# 권한이 부족하면 어떤 Role 이 빠졌는지 알려주고 exit 1 합니다.

source "$(dirname "$0")/00-env.sh"

require_account "${ADMIN_USER}"

FAIL=0

###############################################################################
# 프로젝트 레벨 권한 점검
###############################################################################
check_project() {  # check_project <project> <role 힌트> <permission...>
  local project="$1"; shift
  local hint="$1"; shift
  local perms granted missing=()

  perms="$(printf '%s,' "$@")"; perms="${perms%,}"

  granted="$(gcloud projects test-iam-permissions "${project}" \
    --permissions="${perms}" --format='value(permissions)' 2>/dev/null \
    | tr ';' '\n' | tr ',' '\n' | sed '/^$/d')"

  local p
  for p in "$@"; do
    grep -qx "${p}" <<<"${granted}" || missing+=("${p}")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    printf '  \033[1;32mOK\033[0m   %s :: %s\n' "${project}" "${hint}"
  else
    FAIL=1
    printf '  \033[1;31mFAIL\033[0m %s :: %s\n' "${project}" "${hint}"
    printf '       부족: %s\n' "${missing[*]}"
  fi
}

log "배포 주체 권한 점검: $(current_account)"
echo

echo "[Edge] ${EDGE_PROJECT}"
check_project "${EDGE_PROJECT}" "roles/cloudbuild.connectionAdmin (20 단계)" \
  cloudbuild.connections.list \
  cloudbuild.connections.get \
  cloudbuild.repositories.create \
  cloudbuild.repositories.list
check_project "${EDGE_PROJECT}" "roles/cloudbuild.builds.editor (30/8 단계)" \
  cloudbuild.builds.create \
  cloudbuild.builds.list
check_project "${EDGE_PROJECT}" "roles/container.admin (30 단계)" \
  container.clusters.create \
  container.clusters.get
check_project "${EDGE_PROJECT}" "roles/iam.serviceAccountAdmin (30 단계)" \
  iam.serviceAccounts.create \
  iam.serviceAccounts.setIamPolicy
check_project "${EDGE_PROJECT}" "roles/resourcemanager.projectIamAdmin (30 단계)" \
  resourcemanager.projects.setIamPolicy
check_project "${EDGE_PROJECT}" "roles/serviceusage.serviceUsageAdmin" \
  serviceusage.services.enable

echo
echo "[Host/AR] ${AR_PROJECT}"
check_project "${AR_PROJECT}" "roles/artifactregistry.admin (30 단계)" \
  artifactregistry.repositories.create \
  artifactregistry.repositories.setIamPolicy \
  artifactregistry.repositories.list
check_project "${AR_PROJECT}" "roles/serviceusage.serviceUsageAdmin" \
  serviceusage.services.enable

echo
echo "[Data] ${DATA_PROJECT}"
check_project "${DATA_PROJECT}" "roles/bigquery.admin (30/12 단계, dataset ACL 수정 포함)" \
  bigquery.datasets.get \
  bigquery.datasets.update \
  bigquery.datasets.getIamPolicy \
  bigquery.jobs.create

###############################################################################
# Subnet 레벨 권한 점검 (10-network.sh 가 부여)
###############################################################################
echo
echo "[Subnet] ${HOST_PROJECT}/${SUBNET_NAME}"
if SUBNET_POLICY="$(gcloud compute networks subnets get-iam-policy "${SUBNET_NAME}" \
     --project="${HOST_PROJECT}" --region="${REGION}" \
     --format='value(bindings.members)' 2>/dev/null)"; then
  if grep -q "user:${ADMIN_USER}" <<<"${SUBNET_POLICY}"; then
    printf '  \033[1;32mOK\033[0m   compute.networkUser 보유 (GKE 생성 가능)\n'
  else
    FAIL=1
    printf '  \033[1;31mFAIL\033[0m compute.networkUser 없음\n'
    printf '       Owner 계정으로 10-network.sh 를 재실행하십시오.\n'
  fi
else
  printf '  \033[1;33mSKIP\033[0m Subnet 정책을 읽을 수 없습니다 (아직 미생성이거나 조회 권한 없음)\n'
fi

###############################################################################
# 결과
###############################################################################
echo
if [[ ${FAIL} -eq 0 ]]; then
  log "점검 통과. 20-source-connection.sh 를 진행하십시오."
else
  cat <<EOF

=== 조치 방법 ===
Owner 계정으로 전환해 00-bootstrap.sh 를 재실행하면 누락된 Role 이 부여됩니다.

  gcloud config set account ${OWNER_USER}
  ./gcloud/00-bootstrap.sh
  ./gcloud/10-network.sh          # Subnet 권한이 FAIL 인 경우
  gcloud config set account ${ADMIN_USER}
  ./gcloud/05-check-permissions.sh

개별 Role 만 부여하려면 (Owner 계정으로):

  gcloud projects add-iam-policy-binding ${EDGE_PROJECT} \\
    --member="user:${ADMIN_USER}" \\
    --role="roles/<위에 표시된 Role>" --condition=None
EOF
  exit 1
fi
