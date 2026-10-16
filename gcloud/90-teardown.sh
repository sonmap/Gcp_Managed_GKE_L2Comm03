#!/usr/bin/env bash
# terraform destroy 대체 - 생성 역순 삭제 (IAM 바인딩은 수동 정리 필요)
# 위험한 작업이므로 각 단계마다 확인을 받습니다.

source "$(dirname "$0")/00-env.sh"

# 자원 생성/운영 단계 -> 배포 주체로 실행 (Owner 아님)
require_account "${ADMIN_USER}"

confirm() { read -r -p "$1 [y/N] " a; [[ "${a}" == "y" || "${a}" == "Y" ]]; }

confirm "GKE Cluster ${CLUSTER_NAME} 삭제? (수십 분 소요)" && \
  gcloud container clusters delete "${CLUSTER_NAME}" --project="${EDGE_PROJECT}" --region="${REGION}" --quiet

confirm "Cloud Build Trigger ${CB_TRIGGER} 삭제?" && \
  gcloud builds triggers delete "${CB_TRIGGER}" --project="${EDGE_PROJECT}" --region="${REGION}" --quiet

confirm "Artifact Registry ${AR_PROJECT}/${AR_PYTHON} / ${AR_HELM} 삭제? (이미지 전부 삭제됨)" && {
  gcloud artifacts repositories delete "${AR_PYTHON}" --project="${AR_PROJECT}" --location="${REGION}" --quiet
  gcloud artifacts repositories delete "${AR_HELM}"   --project="${AR_PROJECT}" --location="${REGION}" --quiet
}

confirm "Subnet ${SUBNET_NAME} 삭제? (Cluster 삭제 완료 후에만 가능)" && \
  gcloud compute networks subnets delete "${SUBNET_NAME}" --project="${HOST_PROJECT}" --region="${REGION}" --quiet

echo
echo "서비스 계정과 IAM 바인딩은 자동 삭제하지 않습니다."
echo "필요 시 아래를 직접 실행하십시오:"
echo "  gcloud iam service-accounts delete ${SA_GKE} --project=${EDGE_PROJECT}"
echo "  gcloud projects remove-iam-policy-binding ... (부여한 role 역순)"
