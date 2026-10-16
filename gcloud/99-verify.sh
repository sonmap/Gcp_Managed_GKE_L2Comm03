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

echo "=== Workflow ==="
gcloud workflows describe "${WORKFLOW_NAME}" \
  --project="${EDGE_PROJECT}" --location="${REGION}" \
  --format="yaml(name, state, serviceAccount, revisionId)"

echo "=== Scheduler ==="
gcloud scheduler jobs describe "${SCHEDULER_JOB}" \
  --project="${EDGE_PROJECT}" --location="${REGION}" \
  --format="yaml(name, schedule, timeZone, state, httpTarget.uri)"

echo "=== 최근 Workflow 실행 ==="
gcloud workflows executions list "${WORKFLOW_NAME}" \
  --project="${EDGE_PROJECT}" --location="${REGION}" --limit=5 \
  --format="table(name.basename(), state, startTime, endTime)"

echo "=== BigQuery 결과 ==="
bq query --project_id="${DATA_PROJECT}" --use_legacy_sql=false \
  "SELECT COUNT(*) AS row_count FROM \`${DATA_PROJECT}.${TARGET_DATASET}.${TARGET_TABLE}\`"
