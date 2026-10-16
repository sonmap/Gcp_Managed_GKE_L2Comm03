#!/usr/bin/env bash
# terraform/30-infra-manager/main.tf 의 gcloud 등가 구현
# (Infrastructure Manager Deployment 자체가 불필요해집니다. gcloud 가 직접 자원을 만듭니다.)
#
# 선행: 00-bootstrap.sh, 10-network.sh, 20-source-connection.sh

source "$(dirname "$0")/00-env.sh"

# 자원 생성/운영 단계 -> 배포 주체로 실행 (Owner 아님)
require_account "${ADMIN_USER}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

###############################################################################
# 1) Artifact Registry  (google_artifact_registry_repository)
#
#    AR 은 Host(VPC) 프로젝트에 생성합니다: ${AR_PROJECT}
#    Build 주체(Edge 의 sa-l2comm-gke)와 Pull 주체(Edge 의 Autopilot Node SA)가
#    모두 다른 프로젝트에 있으므로 IAM 은 저장소 레벨로 부여합니다(3단계).
###############################################################################
log "Artifact Registry API 활성화: ${AR_PROJECT}"
gcloud services enable artifactregistry.googleapis.com --project="${AR_PROJECT}"

for REPO_PAIR in "${AR_PYTHON}:L2Comm Python batch images" "${AR_HELM}:L2Comm offline OCI Helm charts"; do
  REPO="${REPO_PAIR%%:*}"; DESC="${REPO_PAIR#*:}"
  log "Artifact Registry: ${AR_PROJECT}/${REPO}"
  ok_if_exists gcloud artifacts repositories create "${REPO}" \
    --project="${AR_PROJECT}" \
    --location="${REGION}" \
    --repository-format=docker \
    --description="${DESC}"
done

###############################################################################
# 2) 통합 서비스 계정  (google_service_account)
#
#    L2Comm02 의 sa-l2comm-runtime / sa-l2comm-workflow / sa-l2comm-cloudbuild
#    3개를 sa-l2comm-gke 하나로 통합했습니다.
###############################################################################
ok_if_exists gcloud iam service-accounts create "${SA_GKE_NAME}" \
  --project="${EDGE_PROJECT}" \
  --display-name="L2Comm GKE 통합 SA (Build / Workflow / Runtime)"

###############################################################################
# 3) IAM  (google_project_iam_member / google_bigquery_dataset_iam_member)
#
#    통합 SA 는 기존 3개 SA Role 의 합집합을 갖습니다.
###############################################################################
bind_project "${EDGE_PROJECT}" "serviceAccount:${SA_GKE}" \
  roles/bigquery.jobUser \
  roles/compute.viewer \
  roles/logging.logWriter \
  roles/storage.objectViewer

bind_project "${EDGE_PROJECT}" "serviceAccount:${AUTOPILOT_NODE_SA}" \
  roles/container.defaultNodeServiceAccount

# Job 생성 주체 권한.
# Workflows 를 쓰지 않으므로 run-gke.sh 를 실행하는 VM / 사용자가 직접 Job 을 만듭니다.
bind_project "${EDGE_PROJECT}" "user:${ADMIN_USER}" roles/container.developer
bind_project "${EDGE_PROJECT}" "serviceAccount:${VM_SA}" roles/container.developer

# 배포 주체가 통합 SA 를 지정해 Workflow/Trigger 를 만들려면 actAs 권한이 필요합니다.
bind_sa "${SA_GKE}" "user:${ADMIN_USER}" roles/iam.serviceAccountUser

# BigQuery Dataset IAM - gcloud 에는 dataset 레벨 명령이 없으므로 bq CLI 사용
#
# 2가지 방식을 순서대로 시도합니다.
#   1) bq add-iam-policy-binding --dataset  (신식. 조직에 따라 allowlist 필요)
#   2) dataset ACL 직접 수정                (bq show -> JSON 편집 -> bq update)
# 2)의 WRITER 는 roles/bigquery.dataEditor 와 동등합니다.
log "BigQuery dataset IAM: ${DATA_PROJECT}:${TARGET_DATASET}"

bq_dataset_bind_iam() {
  bq --project_id="${DATA_PROJECT}" add-iam-policy-binding \
    --dataset=true \
    --member="serviceAccount:${SA_GKE}" \
    --role="roles/bigquery.dataEditor" \
    "${DATA_PROJECT}:${TARGET_DATASET}" 2>&1
}

bq_dataset_bind_acl() {
  local tmp="${TMPDIR:-/tmp}/l2comm-dataset-${TARGET_DATASET}.json"

  bq --project_id="${DATA_PROJECT}" show --format=prettyjson \
    "${DATA_PROJECT}:${TARGET_DATASET}" > "${tmp}"

  python3 -I - "${tmp}" "${SA_GKE}" <<'PY'
import json, sys
path, sa = sys.argv[1], sys.argv[2]
with open(path) as f:
    ds = json.load(f)

access = ds.setdefault("access", [])
for entry in access:
    if entry.get("userByEmail") == sa and entry.get("role") in ("WRITER", "roles/bigquery.dataEditor"):
        print("ALREADY_PRESENT")
        break
else:
    access.append({"role": "WRITER", "userByEmail": sa})
    with open(path, "w") as f:
        json.dump(ds, f)
    print("ADDED")
PY

  bq --project_id="${DATA_PROJECT}" update --source="${tmp}" \
    "${DATA_PROJECT}:${TARGET_DATASET}"
  rm -f "${tmp}"
}

set +e
BQ_OUT="$(bq_dataset_bind_iam)"; BQ_RC=$?
set -e

if [[ ${BQ_RC} -ne 0 ]]; then
  if grep -qi "allowlist\|not supported\|Unknown argument\|dataset" <<<"${BQ_OUT}"; then
    log "add-iam-policy-binding 사용 불가 -> dataset ACL 방식으로 전환"
    log "  (사유: $(head -1 <<<"${BQ_OUT}"))"
    bq_dataset_bind_acl
  else
    printf '%s\n' "${BQ_OUT}" >&2
    exit "${BQ_RC}"
  fi
else
  printf '%s\n' "${BQ_OUT}"
fi

# Artifact Registry 저장소 레벨 IAM  (google_artifact_registry_repository_iam_member)
#
# AR 이 Host 프로젝트에 있으므로 Edge 프로젝트의 project IAM 으로는 닿지 않습니다.
# 반드시 저장소(repository) 레벨로 부여해야 합니다.
#
#   writer : sa-l2comm-gke       (Cloud Build 가 Image Push)
#   reader : Autopilot Node SA   (Pod Image Pull)
#            VM SA               (VM 에서 docker/crane 조회)
#            배포 주체           (gcloud artifacts ... 확인용)
ar_bind() {  # ar_bind <repo> <member> <role>
  log "AR IAM :: ${AR_PROJECT}/${1} :: ${2} -> ${3}"
  gcloud artifacts repositories add-iam-policy-binding "${1}" \
    --project="${AR_PROJECT}" --location="${REGION}" \
    --member="${2}" --role="${3}" --quiet >/dev/null
}

for REPO in "${AR_PYTHON}" "${AR_HELM}"; do
  ar_bind "${REPO}" "serviceAccount:${SA_GKE}" roles/artifactregistry.writer
done

for MEMBER in "${AUTOPILOT_NODE_SA}" "${VM_SA}"; do
  ar_bind "${AR_PYTHON}" "serviceAccount:${MEMBER}" roles/artifactregistry.reader
done

ar_bind "${AR_PYTHON}" "user:${ADMIN_USER}" roles/artifactregistry.reader

###############################################################################
# 4) Cloud Build Trigger  (google_cloudbuild_trigger)
#    2nd-gen repository 참조이므로 `--repository` 플래그를 사용합니다.
###############################################################################
log "Cloud Build Trigger: ${CB_TRIGGER}"
if gcloud builds triggers describe "${CB_TRIGGER}" \
     --project="${EDGE_PROJECT}" --region="${REGION}" >/dev/null 2>&1; then
  log "SKIP (이미 존재): ${CB_TRIGGER} — 변경이 필요하면 'gcloud builds triggers update' 사용"
else
  gcloud builds triggers create github "${CB_TRIGGER}" \
    --project="${EDGE_PROJECT}" \
    --region="${REGION}" \
    --description="Auto-build L2Comm Python image on source updates" \
    --repository="projects/${EDGE_PROJECT}/locations/${REGION}/connections/${CB_CONNECTION}/repositories/${CB_REPO}" \
    --branch-pattern='^main$' \
    --build-config="cloudbuild/cloudbuild.yaml" \
    --service-account="projects/${EDGE_PROJECT}/serviceAccounts/${SA_GKE}" \
    --included-files="app/**,cloudbuild/**,gcloud/**"
fi

###############################################################################
# 5) GKE Autopilot Cluster  (google_container_cluster)
#    - Shared VPC 의 network/subnetwork 를 full path 로 지정
#    - Pod 2차 대역만 지정, Service 대역은 GKE managed
#    - Private nodes + Private endpoint + master CIDR
#
#    --enable-private-endpoint 를 쓰면 --enable-master-authorized-networks 가
#    반드시 함께 있어야 합니다(없으면 400 에러).
#    다만 --no-enable-authorized-networks-on-private-endpoint 로 Private IP
#    경로에는 CIDR 제한을 걸지 않습니다. 관리 VM 의 대역이 RFC1918 이 아닐 수
#    있어 L2Comm02 와 동일하게 유지한 설정입니다.
#    운영 전환 시 제한이 필요하면 아래를 추가하십시오.
#      --master-authorized-networks=10.252.1.0/24,<관리 VM CIDR>
#      --enable-authorized-networks-on-private-endpoint
#
#    Private nodes 이므로 공인 인터넷에서 컨테이너를 받아야 한다면 Cloud NAT 가
#    필요합니다. 이 PoC 는 Artifact Registry(Private Google Access)만 사용하므로
#    Subnet 의 private-ip-google-access(10-network.sh 에서 설정)로 충분합니다.
###############################################################################
log "GKE Autopilot Cluster: ${CLUSTER_NAME}"
if gcloud container clusters describe "${CLUSTER_NAME}" \
     --project="${EDGE_PROJECT}" --region="${REGION}" >/dev/null 2>&1; then
  log "SKIP (이미 존재): ${CLUSTER_NAME}"
else
  gcloud container clusters create-auto "${CLUSTER_NAME}" \
    --project="${EDGE_PROJECT}" \
    --region="${REGION}" \
    --network="projects/${HOST_PROJECT}/global/networks/${NETWORK_NAME}" \
    --subnetwork="projects/${HOST_PROJECT}/regions/${REGION}/subnetworks/${SUBNET_NAME}" \
    --cluster-secondary-range-name="${POD_RANGE_NAME}" \
    --enable-private-nodes \
    --enable-private-endpoint \
    --master-ipv4-cidr="${CONTROL_PLANE_CIDR}" \
    --enable-master-authorized-networks \
    --no-enable-authorized-networks-on-private-endpoint
fi

# Autopilot 은 Workload Identity 가 항상 활성화되며 workload pool 은
# <PROJECT_ID>.svc.id.goog 로 고정됩니다. create-auto 는 --workload-pool 플래그를
# 받지 않으므로(Standard 전용) 지정하지 않고, 생성 후 값만 검증합니다.
ACTUAL_POOL="$(gcloud container clusters describe "${CLUSTER_NAME}" \
  --project="${EDGE_PROJECT}" --region="${REGION}" \
  --format='value(workloadIdentityConfig.workloadPool)' 2>/dev/null)"

if [[ "${ACTUAL_POOL}" == "${EDGE_PROJECT}.svc.id.goog" ]]; then
  log "Workload Identity pool 확인: ${ACTUAL_POOL}"
else
  echo "ERROR: Workload Identity pool 이 예상과 다릅니다." >&2
  echo "       기대: ${EDGE_PROJECT}.svc.id.goog" >&2
  echo "       실제: ${ACTUAL_POOL:-<없음>}" >&2
  exit 1
fi

###############################################################################
# 6) Workload Identity 바인딩  (google_service_account_iam_member)
###############################################################################
bind_sa "${SA_GKE}" \
  "serviceAccount:${EDGE_PROJECT}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]" \
  roles/iam.workloadIdentityUser

###############################################################################
# 7) Namespace / KSA 사전 생성
#
#    Workflows 를 사용하지 않으므로 Namespace 와 KSA 는 여기서 만들어 둡니다.
#    (ssw/dlk/client_gke 도 없으면 생성하지만, Autopilot 첫 기동 지연을 줄이기 위해
#     플랫폼 구축 단계에서 미리 만듭니다.)
#    Private endpoint 클러스터이므로 VPC 내부에서 실행해야 합니다.
###############################################################################
if [[ "${SETUP_K8S:-auto}" != "false" ]]; then
  log "Namespace / KSA 생성 시도 (VPC 내부에서만 성공)"
  if gcloud container clusters get-credentials "${CLUSTER_NAME}" \
       --project="${EDGE_PROJECT}" --region="${REGION}" --internal-ip >/dev/null 2>&1 \
     && kubectl version >/dev/null 2>&1; then
    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 \
      || kubectl create namespace "${NAMESPACE}"
    kubectl -n "${NAMESPACE}" get serviceaccount "${KSA_NAME}" >/dev/null 2>&1 \
      || kubectl -n "${NAMESPACE}" create serviceaccount "${KSA_NAME}"
    kubectl -n "${NAMESPACE}" annotate serviceaccount "${KSA_NAME}" \
      "iam.gke.io/gcp-service-account=${SA_GKE}" --overwrite
    log "Namespace / KSA 준비 완료"
  else
    log "SKIP: Control Plane 에 접근할 수 없습니다 (VPC 외부이거나 kubectl 미설치)."
    log "      VPC 내부 VM 에서 ssw/dlk/client_gke 실행 시 자동 생성됩니다."
  fi
fi

###############################################################################
# 8) terraform output 대체
###############################################################################
cat <<EOF

=== Outputs ===
cluster_name             : ${CLUSTER_NAME}
artifact_image           : ${IMAGE_URI}
artifact_registry        : ${AR_PROJECT} (Host 프로젝트)
helm_oci_repository      : ${HELM_OCI_URI}
cloudbuild_trigger_name  : ${CB_TRIGGER}
namespace                : ${NAMESPACE}
ksa                      : ${KSA_NAME}
service_account          : ${SA_GKE}   (Build / Runtime 통합)

=== 배치 실행 (Workflow/Scheduler 미사용) ===
VPC 내부 VM 에서:
  DOCKER_IMAGE=${IMAGE_URI} \\
  ./ssw/dlk/run-gke.sh 20261016 20261016 20261016 180000 0 4 16 \\
    /mnt/l2comm/python python bq_sample.py
EOF

log "30-platform 완료"
