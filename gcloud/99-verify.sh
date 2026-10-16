#!/usr/bin/env bash
# terraform plan / output 대체 - 생성 자원 상태 일괄 점검

source "$(dirname "$0")/00-env.sh"
set +e

echo "=== Subnet ==="
gcloud compute networks subnets describe "${SUBNET_NAME}" \
  --project="${HOST_PROJECT}" --region="${REGION}" \
  --format="yaml(name, ipCidrRange, secondaryIpRanges, privateIpGoogleAccess)"

echo "=== GKE Cluster ==="
gcloud container clusters describe "${CLUSTER_NAME}" \
  --project="${EDGE_PROJECT}" --region="${REGION}" \
  --format="yaml(name, autopilot.enabled, network, subnetwork,
                 ipAllocationPolicy.clusterSecondaryRangeName,
                 ipAllocationPolicy.servicesIpv4Cidr,
                 privateClusterConfig.masterIpv4CidrBlock,
                 privateClusterConfig.enablePrivateEndpoint,
                 workloadIdentityConfig.workloadPool, status)"

echo "=== Artifact Registry ==="
gcloud artifacts repositories list --project="${EDGE_PROJECT}" --location="${REGION}" \
  --format="table(name, format)"

echo "=== Cloud Build Trigger ==="
gcloud builds triggers list --project="${EDGE_PROJECT}" --region="${REGION}" \
  --format="table(name, serviceAccount, filename)"

echo "=== 통합 SA ==="
gcloud iam service-accounts describe "${SA_GKE}" \
  --project="${EDGE_PROJECT}" --format="yaml(email, displayName, disabled)"

echo "=== 최근 GKE Job (VPC 내부에서만 조회 가능) ==="
if gcloud container clusters get-credentials "${CLUSTER_NAME}" \
     --project="${EDGE_PROJECT}" --region="${REGION}" --internal-ip >/dev/null 2>&1 \
   && kubectl version >/dev/null 2>&1; then
  kubectl -n "${NAMESPACE}" get jobs --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -10
  echo "--- KSA 어노테이션 ---"
  kubectl -n "${NAMESPACE}" get serviceaccount "${KSA_NAME}" \
    -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}{"\n"}' 2>/dev/null
else
  echo "SKIP: Control Plane 에 접근할 수 없습니다 (VPC 외부이거나 kubectl 미설치)."
fi

echo "=== BigQuery 결과 ==="
bq query --project_id="${DATA_PROJECT}" --use_legacy_sql=false \
  "SELECT COUNT(*) AS row_count FROM \`${DATA_PROJECT}.${TARGET_DATASET}.${TARGET_TABLE}\`"
