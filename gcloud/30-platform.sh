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
# 2) 서비스 계정  (google_service_account)
###############################################################################
ok_if_exists gcloud iam service-accounts create sa-l2comm-runtime \
  --project="${EDGE_PROJECT}" --display-name="L2Comm GKE Python runtime"
ok_if_exists gcloud iam service-accounts create sa-l2comm-workflow \
  --project="${EDGE_PROJECT}" --display-name="L2Comm Workflow GKE Job launcher"
ok_if_exists gcloud iam service-accounts create sa-l2comm-cloudbuild \
  --project="${EDGE_PROJECT}" --display-name="L2Comm Cloud Build"

###############################################################################
# 3) IAM  (google_project_iam_member / google_bigquery_dataset_iam_member)
###############################################################################
bind_project "${EDGE_PROJECT}" "serviceAccount:${SA_RUNTIME}" \
  roles/bigquery.jobUser \
  roles/compute.viewer

bind_project "${EDGE_PROJECT}" "serviceAccount:${SA_WORKFLOW}" \
  roles/container.developer \
  roles/workflows.invoker

bind_project "${EDGE_PROJECT}" "serviceAccount:${SA_CLOUDBUILD}" \
  roles/artifactregistry.writer \
  roles/logging.logWriter \
  roles/storage.objectViewer

bind_project "${EDGE_PROJECT}" "serviceAccount:${AUTOPILOT_NODE_SA}" \
  roles/container.defaultNodeServiceAccount

# BigQuery Dataset IAM - gcloud 에는 dataset 레벨 명령이 없으므로 bq CLI 사용
log "BigQuery dataset IAM: ${DATA_PROJECT}:${TARGET_DATASET}"
bq --project_id="${DATA_PROJECT}" add-iam-policy-binding \
  --dataset=true \
  --member="serviceAccount:${SA_RUNTIME}" \
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
    --service-account="projects/${EDGE_PROJECT}/serviceAccounts/${SA_CLOUDBUILD}" \
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
bind_sa "${SA_RUNTIME}" \
  "serviceAccount:${EDGE_PROJECT}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]" \
  roles/iam.workloadIdentityUser

###############################################################################
# 7) Workflow 배포  (google_workflows_workflow + templatefile)
#    templatefile() 대신 sed 로 렌더링 후 --source 로 배포
###############################################################################
RENDERED="$(mktemp -d)/workflow.yaml"
sed \
  -e "s|@@EDGE_PROJECT@@|${EDGE_PROJECT}|g" \
  -e "s|@@REGION@@|${REGION}|g" \
  -e "s|@@CLUSTER_NAME@@|${CLUSTER_NAME}|g" \
  -e "s|@@NAMESPACE@@|${NAMESPACE}|g" \
  -e "s|@@KSA_NAME@@|${KSA_NAME}|g" \
  -e "s|@@SA_RUNTIME@@|${SA_RUNTIME}|g" \
  -e "s|@@IMAGE_URI@@|${IMAGE_URI}|g" \
  -e "s|@@DATA_PROJECT@@|${DATA_PROJECT}|g" \
  -e "s|@@TARGET_DATASET@@|${TARGET_DATASET}|g" \
  -e "s|@@TARGET_TABLE@@|${TARGET_TABLE}|g" \
  "${SCRIPT_DIR}/workflow.yaml.tmpl" > "${RENDERED}"

log "Workflow 배포: ${WORKFLOW_NAME}  (렌더링 결과: ${RENDERED})"
# workflows deploy 는 생성/갱신 겸용이라 멱등합니다.
gcloud workflows deploy "${WORKFLOW_NAME}" \
  --project="${EDGE_PROJECT}" \
  --location="${REGION}" \
  --source="${RENDERED}" \
  --service-account="${SA_WORKFLOW}" \
  --description="Create and wait for the L2Comm Kubernetes Job on GKE Autopilot"

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
runtime_service_account  : ${SA_RUNTIME}
workflow_service_account : ${SA_WORKFLOW}
workflow_name            : ${WORKFLOW_NAME}
EOF

log "30-platform 완료"
