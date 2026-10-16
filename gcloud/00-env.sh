#!/usr/bin/env bash
# 공통 환경변수 - 모든 스크립트가 이 파일을 source 합니다.
# terraform/*/terraform.tfvars.example 값과 1:1 대응합니다.

set -Eeuo pipefail

# ---- Project / Region (00-bootstrap, 10-network, 30-infra-manager 공통) ----
export EDGE_PROJECT="gcp-prod-edp-edge-509423"
export HOST_PROJECT="gcp-prod-edp-hub-vpchost"
export DATA_PROJECT="pjt-c-admin"
export REGION="asia-northeast3"

# ---- 계정 분리 ----
#
# OWNER_USER  : Organization/Project Owner.
#               **권한(IAM)을 부여할 때만** 사용합니다. 즉 00-bootstrap.sh 전용.
#               자원 생성/운영에는 사용하지 않습니다.
#
# ADMIN_USER  : 실제 배포/운영 주체.
#               00-bootstrap.sh 에서 Role 을 받은 뒤 10 단계부터 모든 작업을 수행합니다.
#
export OWNER_USER="admin@sonmap.net"
export ADMIN_USER="cho@sonmap.net"
export VM_SA="620081195575-compute@developer.gserviceaccount.com"
export TFSTATE_BUCKET="gcp-prod-edp-edge-509423-l2comm-tfstate"   # gcloud 전환 시 선택사항

# ---- Network ----
export NETWORK_NAME="vpc-prod-edp-hub"
export SUBNET_NAME="subnet-prod-edp-l2comm-gke-an3"
export NODE_CIDR="10.252.1.0/24"
export POD_RANGE_NAME="pods-prod-edp-l2comm-an3"
export POD_CIDR="100.64.128.0/19"
export CONTROL_PLANE_CIDR="10.254.5.0/28"

# ---- Platform (30) ----
export CLUSTER_NAME="gke-l2comm-batch-an3"
# Artifact Registry 는 Host(VPC) 프로젝트에 둡니다.
# Build(Edge) / Pull(Edge Node) 이 모두 크로스 프로젝트로 동작합니다.
export AR_PROJECT="${HOST_PROJECT}"
export AR_PYTHON="ar-l2comm-python"
export AR_HELM="ar-l2comm-helm"
export IMAGE_NAME="python-bq-batch"
export IMAGE_TAG="v1"
export NAMESPACE="l2comm-batch"
export KSA_NAME="ksa-l2comm-batch"
export AUTOPILOT_NODE_SA="541022739403-compute@developer.gserviceaccount.com"

# ---- Cloud Build (20 / 30) ----
export CB_CONNECTION="github-l2comm"
export CB_REPO="Gcp_Managed_GKE_L2Comm03"
export CB_REMOTE_URI="https://github.com/sonmap/Gcp_Managed_GKE_L2Comm03.git"
export CB_TRIGGER="trg-l2comm-python-image"

# ---- BigQuery ----
export TARGET_DATASET="dlk_sample"
export TARGET_TABLE="gcp_region_inventory"

# ---- Batch 실행 (run-gke.sh / client_gke) ----
# Workflows / Cloud Scheduler 를 사용하지 않습니다.
# 정기 실행이 필요하면 VM 의 crontab 에서 run-gke.sh 를 호출합니다.
export POD_MOUNT_PATH="${POD_MOUNT_PATH:-/mnt/l2comm}"

# ---- 파생값 ----
# 통합 서비스 계정.
# L2Comm02 의 sa-l2comm-runtime / sa-l2comm-workflow / sa-l2comm-cloudbuild 를
# 하나로 합친 것입니다. Build / Workflow / Runtime 전 구간에서 사용합니다.
export SA_GKE_NAME="sa-l2comm-gke"
export SA_GKE="${SA_GKE_NAME}@${EDGE_PROJECT}.iam.gserviceaccount.com"
export IMAGE_URI="${REGION}-docker.pkg.dev/${AR_PROJECT}/${AR_PYTHON}/${IMAGE_NAME}:${IMAGE_TAG}"
export HELM_OCI_URI="oci://${REGION}-docker.pkg.dev/${AR_PROJECT}/${AR_HELM}"

EDGE_PROJECT_NUMBER="$(gcloud projects describe "${EDGE_PROJECT}" --format='value(projectNumber)')"
export EDGE_PROJECT_NUMBER
export GKE_SERVICE_AGENT="service-${EDGE_PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com"
export CLOUD_SERVICES_SA="${EDGE_PROJECT_NUMBER}@cloudservices.gserviceaccount.com"
export CLOUDBUILD_P4SA="service-${EDGE_PROJECT_NUMBER}@gcp-sa-cloudbuild.iam.gserviceaccount.com"

# ---- 공통 헬퍼 ----
# terraform 은 state 로 "이미 존재함"을 판별하지만 gcloud 는 그렇지 않습니다.
# 아래 헬퍼로 재실행(멱등성)을 보장합니다.

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

# 현재 gcloud 활성 계정
current_account() { gcloud config get-value account 2>/dev/null; }

# 실행 계정 확인.
#   require_account "${OWNER_USER}"  -> Owner 로 실행해야 하는 단계 (권한 부여)
#   require_account "${ADMIN_USER}"  -> 배포 주체로 실행해야 하는 단계
# SKIP_ACCOUNT_CHECK=1 로 우회할 수 있습니다.
require_account() {
  local expected="$1" actual
  actual="$(current_account)"

  if [[ "${SKIP_ACCOUNT_CHECK:-0}" == "1" ]]; then
    log "계정 확인 생략 (SKIP_ACCOUNT_CHECK=1). 현재 계정: ${actual:-<없음>}"
    return 0
  fi

  if [[ -z "${actual}" ]]; then
    echo "ERROR: gcloud 활성 계정이 없습니다. 먼저 로그인하십시오:" >&2
    echo "  gcloud auth login ${expected}" >&2
    exit 1
  fi

  if [[ "${actual}" != "${expected}" ]]; then
    cat >&2 <<MSG
ERROR: 이 단계는 '${expected}' 계정으로 실행해야 합니다.
       현재 계정: ${actual}

  계정 분리 원칙
    ${OWNER_USER}  : Owner. 권한(IAM) 부여 전용 -> 00-bootstrap.sh
    ${ADMIN_USER}  : 배포/운영 주체          -> 10 단계 이후 전부

  전환:
    gcloud config set account ${expected}
    (최초 1회) gcloud auth login ${expected}

  의도적으로 다른 계정을 쓰려면 SKIP_ACCOUNT_CHECK=1 을 지정하십시오.
MSG
    exit 1
  fi

  log "실행 계정 확인: ${actual}"
}

# 이미 존재하면 409 를 무시하고 넘어감
ok_if_exists() {
  local out rc
  set +e
  out="$("$@" 2>&1)"; rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    if grep -qiE 'already exists|ALREADY_EXISTS|AlreadyExists' <<<"${out}"; then
      log "SKIP (이미 존재): $*"
      return 0
    fi
    printf '%s\n' "${out}" >&2
    return $rc
  fi
  printf '%s\n' "${out}"
}

# 프로젝트 IAM 바인딩 (additive, 멱등)
bind_project() {  # bind_project <project> <member> <role...>
  local project="$1"; shift
  local member="$1"; shift
  local role
  for role in "$@"; do
    log "IAM ${project} :: ${member} -> ${role}"
    gcloud projects add-iam-policy-binding "${project}" \
      --member="${member}" --role="${role}" \
      --condition=None --quiet >/dev/null
  done
}

# 서비스계정 리소스 IAM 바인딩
bind_sa() {  # bind_sa <sa_email> <member> <role> [project]
  local sa="$1" member="$2" role="$3" project="${4:-$EDGE_PROJECT}"
  log "IAM SA ${sa} :: ${member} -> ${role}"
  gcloud iam service-accounts add-iam-policy-binding "${sa}" \
    --project="${project}" --member="${member}" --role="${role}" \
    --condition=None --quiet >/dev/null
}
