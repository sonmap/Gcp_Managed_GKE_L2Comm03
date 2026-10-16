#!/usr/bin/env bash
# terraform/30-infra-manager/main.tf 의 gcloud 등가 구현
# (Infrastructure Manager Deployment 자체가 불필요해집니다. gcloud 가 직접 자원을 만듭니다.)
#
# 선행: 00-bootstrap.sh, 10-network.sh, 20-source-connection.sh

source "$(dirname "$0")/00-env.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

###############################################################################
# 1) Artifact Registry  (google_artifact_registry_repository)
###############################################################################
for REPO_PAIR in "${AR_PYTHON}:L2Comm Python batch images" "${AR_HELM}:L2Comm offline OCI Helm charts"; do
  REPO="${REPO_PAIR%%:*}"; DESC="${REPO_PAIR#*:}"
  log "Artifact Registry: ${REPO}"
  ok_if_exists gcloud artifacts repositories create "${REPO}" \
    --project="${EDGE_PROJECT}" \
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
  roles/artifactregistry.writer \
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
log "BigQuery dataset IAM: ${DATA_PROJECT}:${TARGET_DATASET}"
bq --project_id="${DATA_PROJECT}" add-iam-policy-binding \
  --dataset=true \
  --member="serviceAccount:${SA_GKE}" \
  --role="roles/bigquery.dataEditor" \
  "${DATA_PROJECT}:${TARGET_DATASET}"

# Artifact Registry 저장소 레벨 IAM  (google_artifact_registry_repository_iam_member)
for MEMBER in "${VM_SA}" "${AUTOPILOT_NODE_SA}"; do
  log "AR IAM :: ${MEMBER} -> roles/artifactregistry.reader"
  gcloud artifacts repositories add-iam-policy-binding "${AR_PYTHON}" \
    --project="${EDGE_PROJECT}" --location="${REGION}" \
    --member="serviceAccount:${MEMBER}" \
    --role=roles/artifactregistry.reader --quiet >/dev/null
done

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
    --no-enable-authorized-networks-on-private-endpoint \
    --workload-pool="${EDGE_PROJECT}.svc.id.goog"
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
helm_oci_repository      : oci://${REGION}-docker.pkg.dev/${EDGE_PROJECT}/${AR_HELM}
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
