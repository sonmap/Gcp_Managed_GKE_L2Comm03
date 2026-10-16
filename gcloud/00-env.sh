#!/usr/bin/env bash
# 공통 환경변수 - 모든 스크립트가 이 파일을 source 합니다.
# terraform/*/terraform.tfvars.example 값과 1:1 대응합니다.

set -Eeuo pipefail

# ---- Project / Region (00-bootstrap, 10-network, 30-infra-manager 공통) ----
export EDGE_PROJECT="gcp-prod-edp-edge-509423"
export HOST_PROJECT="gcp-prod-edp-hub-vpchost"
export DATA_PROJECT="pjt-c-admin"
export REGION="asia-northeast3"

# ---- Bootstrap ----
export ADMIN_USER="chomap@sonmap.net"
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
export AR_PYTHON="ar-l2comm-python"
export AR_HELM="ar-l2comm-helm"
export IMAGE_NAME="python-bq-batch"
export IMAGE_TAG="v1"
export NAMESPACE="l2comm-batch"
export KSA_NAME="ksa-l2comm-batch"
export WORKFLOW_NAME="wf-l2comm-gke-job"
export AUTOPILOT_NODE_SA="541022739403-compute@developer.gserviceaccount.com"

# ---- Cloud Build (20 / 30) ----
export CB_CONNECTION="github-l2comm"
export CB_REPO="Gcp_Managed_GKE_L2Comm03"
export CB_REMOTE_URI="https://github.com/sonmap/Gcp_Managed_GKE_L2Comm03.git"
export CB_TRIGGER="trg-l2comm-python-image"

# ---- BigQuery ----
export TARGET_DATASET="dlk_sample"
export TARGET_TABLE="gcp_region_inventory"

# ---- Scheduler (40) ----
export SCHEDULER_JOB="sch-l2comm-gke-job"
export SCHEDULE_CRON="0 9 * * *"
export SCHEDULE_TZ="Asia/Seoul"

# ---- 파생값 ----
# 통합 서비스 계정.
# L2Comm02 의 sa-l2comm-runtime / sa-l2comm-workflow / sa-l2comm-cloudbuild 를
# 하나로 합친 것입니다. Build / Workflow / Runtime 전 구간에서 사용합니다.
export SA_GKE_NAME="sa-l2comm-gke"
export SA_GKE="${SA_GKE_NAME}@${EDGE_PROJECT}.iam.gserviceaccount.com"
export IMAGE_URI="${REGION}-docker.pkg.dev/${EDGE_PROJECT}/${AR_PYTHON}/${IMAGE_NAME}:${IMAGE_TAG}"

EDGE_PROJECT_NUMBER="$(gcloud projects describe "${EDGE_PROJECT}" --format='value(projectNumber)')"
export EDGE_PROJECT_NUMBER
export GKE_SERVICE_AGENT="service-${EDGE_PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com"
export CLOUD_SERVICES_SA="${EDGE_PROJECT_NUMBER}@cloudservices.gserviceaccount.com"
export CLOUDBUILD_P4SA="service-${EDGE_PROJECT_NUMBER}@gcp-sa-cloudbuild.iam.gserviceaccount.com"

# ---- 공통 헬퍼 ----
# terraform 은 state 로 "이미 존재함"을 판별하지만 gcloud 는 그렇지 않습니다.
# 아래 헬퍼로 재실행(멱등성)을 보장합니다.

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

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
