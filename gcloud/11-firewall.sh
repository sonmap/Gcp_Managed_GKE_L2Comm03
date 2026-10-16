#!/usr/bin/env bash
# Host 프로젝트 방화벽 규칙 구성
#
# ** 이 스크립트는 Owner 계정(admin@sonmap.net)으로 실행합니다. **
# Host 프로젝트 네트워크 변경이므로 네트워크 관리 영역입니다.
#
# 생성하는 규칙 2종:
#   1) GKE Node/Pod -> 관리 VM NFS (tcp:2049)
#      Pod 가 VM 의 NFS export 를 마운트하는 경로.
#   2) GKE Control Plane -> Node (tcp:10250 등)
#      Private cluster 의 konnectivity. 없으면 kubectl logs/exec 가
#      "No agent available" 로 실패합니다.
#      Shared VPC 에서는 GKE 가 이 규칙을 Host 프로젝트에 자동 생성하지
#      못하는 경우가 있어 명시적으로 만듭니다.
#
# 선행: 10-network.sh (Subnet), 30-platform.sh (Cluster) 완료
#
# 환경변수(선택):
#   NFS_VM_NAME / NFS_VM_ZONE / NFS_VM_PROJECT
#     NFS 서버 VM. 생략하면 이 스크립트를 실행 중인 VM 을 메타데이터로 자동 인식.
#   SKIP_NFS_TAG=true   VM 에 태그를 붙이지 않음(이미 붙어 있는 경우)

source "$(dirname "$0")/00-env.sh"

# 네트워크 관리 영역 -> Owner 로 실행
require_account "${OWNER_USER}"

NFS_RULE="${NFS_RULE:-fw-allow-l2comm-nfs}"
MASTER_RULE="${MASTER_RULE:-fw-l2comm-master-to-node}"
NFS_TAG="${NFS_TAG:-l2comm-nfs}"

###############################################################################
# 0) 현재 규칙 확인
###############################################################################
log "현재 ${NETWORK_NAME} 방화벽 규칙"
gcloud compute firewall-rules list \
  --project="${HOST_PROJECT}" \
  --filter="network:${NETWORK_NAME}" \
  --format="table(name, sourceRanges.list(), allowed[].map().firewall_rule().list(), targetTags.list())"
echo

###############################################################################
# 1) GKE Node/Pod -> VM NFS (tcp:2049)
###############################################################################
log "NFS 규칙: ${NFS_RULE}"
if gcloud compute firewall-rules describe "${NFS_RULE}" \
     --project="${HOST_PROJECT}" >/dev/null 2>&1; then
  log "SKIP (이미 존재): ${NFS_RULE}"
else
  gcloud compute firewall-rules create "${NFS_RULE}" \
    --project="${HOST_PROJECT}" \
    --network="${NETWORK_NAME}" \
    --direction=INGRESS --action=ALLOW \
    --rules=tcp:2049 \
    --source-ranges="${NODE_CIDR},${POD_CIDR}" \
    --target-tags="${NFS_TAG}" \
    --description="GKE node/pod -> L2Comm NFS server"
fi

###############################################################################
# 2) NFS 서버 VM 에 태그 부여
###############################################################################
if [[ "${SKIP_NFS_TAG:-false}" != "true" ]]; then
  # 지정이 없으면 이 스크립트를 실행 중인 VM 을 메타데이터로 자동 인식
  MD_ROOT="http://metadata.google.internal/computeMetadata/v1"
  MD="${MD_ROOT}/instance"
  MD_HDR="Metadata-Flavor: Google"

  if [[ -z "${NFS_VM_NAME:-}" ]]; then
    NFS_VM_NAME="$(curl -s -H "${MD_HDR}" "${MD}/name" 2>/dev/null || true)"
  fi
  if [[ -z "${NFS_VM_ZONE:-}" ]]; then
    NFS_VM_ZONE="$(curl -s -H "${MD_HDR}" "${MD}/zone" 2>/dev/null | awk -F/ '{print $NF}' || true)"
  fi
  if [[ -z "${NFS_VM_PROJECT:-}" ]]; then
    # 메타데이터의 project-id 는 VM 이 실제로 속한 프로젝트입니다.
    # (gcloud config 의 프로젝트와 다를 수 있으므로 fallback 으로 쓰지 않습니다)
    NFS_VM_PROJECT="$(curl -s -H "${MD_HDR}" "${MD_ROOT}/project/project-id" 2>/dev/null || true)"
  fi

  if [[ -n "${NFS_VM_NAME}" && -n "${NFS_VM_ZONE}" && -n "${NFS_VM_PROJECT}" ]]; then
    log "NFS VM 태그: ${NFS_VM_PROJECT}/${NFS_VM_ZONE}/${NFS_VM_NAME} -> ${NFS_TAG}"

    # VM 이 보이지 않으면(프로젝트 오인/권한 부족) 전체 실패시키지 않고
    # 안내만 남긴 뒤 Control Plane 규칙 생성으로 진행합니다.
    if ! gcloud compute instances describe "${NFS_VM_NAME}" \
           --zone="${NFS_VM_ZONE}" --project="${NFS_VM_PROJECT}" \
           >/dev/null 2>&1; then
      log "WARN: VM 을 찾지 못했습니다: ${NFS_VM_PROJECT}/${NFS_VM_ZONE}/${NFS_VM_NAME}"
      log "      VM 이 속한 프로젝트를 확인한 뒤 아래처럼 지정해 재실행하십시오."
      log "        gcloud compute instances list --filter=\"name:${NFS_VM_NAME}\" \\"
      log "          --format='table(name, zone.basename(), networkInterfaces[0].networkIP)'"
      log "        NFS_VM_PROJECT=<PRJ> ./gcloud/11-firewall.sh"
    else
      CUR_TAGS="$(gcloud compute instances describe "${NFS_VM_NAME}" \
        --zone="${NFS_VM_ZONE}" --project="${NFS_VM_PROJECT}" \
        --format='value(tags.items.list())' 2>/dev/null || true)"

      if grep -q "${NFS_TAG}" <<<"${CUR_TAGS}"; then
        log "SKIP (이미 태그 보유): ${NFS_TAG}"
      else
        # add-tags 는 기존 태그를 보존합니다.
        gcloud compute instances add-tags "${NFS_VM_NAME}" \
          --zone="${NFS_VM_ZONE}" --project="${NFS_VM_PROJECT}" \
          --tags="${NFS_TAG}"
      fi
    fi
  else
    log "SKIP: NFS VM 을 식별하지 못했습니다(메타데이터 없음)."
    log "      NFS_VM_NAME / NFS_VM_ZONE / NFS_VM_PROJECT 를 지정해 재실행하거나,"
    log "      직접 태그를 부여하십시오:"
    log "        gcloud compute instances add-tags <VM> --zone=<ZONE> --project=<PRJ> --tags=${NFS_TAG}"
  fi
fi

###############################################################################
# 3) GKE Control Plane -> Node (konnectivity / webhook)
###############################################################################
log "노드 네트워크 태그 조회"
NODE_TAG="$(gcloud compute firewall-rules list \
  --project="${HOST_PROJECT}" \
  --filter="name~gke-${CLUSTER_NAME}" \
  --format='value(targetTags.list())' 2>/dev/null | head -1)"

if [[ -z "${NODE_TAG}" ]]; then
  NODE_TAG="$(gcloud compute instances list \
    --project="${EDGE_PROJECT}" \
    --filter="name~gke-${CLUSTER_NAME}" \
    --format='value(tags.items[0])' 2>/dev/null | head -1)"
fi

if [[ -z "${NODE_TAG}" ]]; then
  echo "ERROR: 노드 네트워크 태그를 찾지 못했습니다." >&2
  echo "       클러스터가 생성되어 노드가 하나 이상 기동된 뒤 재실행하십시오." >&2
  echo "       (30-platform.sh 완료 후, 배치를 한 번 실행하면 노드가 뜹니다)" >&2
  exit 1
fi

log "NODE_TAG=${NODE_TAG}"
log "Control Plane 규칙: ${MASTER_RULE}"

if gcloud compute firewall-rules describe "${MASTER_RULE}" \
     --project="${HOST_PROJECT}" >/dev/null 2>&1; then
  log "SKIP (이미 존재): ${MASTER_RULE}"
else
  gcloud compute firewall-rules create "${MASTER_RULE}" \
    --project="${HOST_PROJECT}" \
    --network="${NETWORK_NAME}" \
    --direction=INGRESS --action=ALLOW \
    --rules=tcp:10250,tcp:443,tcp:8443,tcp:9443,tcp:15017 \
    --source-ranges="${CONTROL_PLANE_CIDR}" \
    --target-tags="${NODE_TAG}" \
    --description="GKE control plane -> ${CLUSTER_NAME} nodes (konnectivity, webhooks)"
fi

###############################################################################
# 4) 결과
###############################################################################
echo
log "결과"
gcloud compute firewall-rules list \
  --project="${HOST_PROJECT}" \
  --filter="network:${NETWORK_NAME}" \
  --format="table(name, sourceRanges.list(), allowed[].map().firewall_rule().list(), targetTags.list())" \
  | grep -E "NAME|${NFS_RULE}|${MASTER_RULE}|2049|${CONTROL_PLANE_CIDR}" || true

cat <<EOF

=== 다음 단계 ===
배포 주체로 전환한 뒤 konnectivity 연결을 확인하십시오.

  gcloud config set account ${ADMIN_USER}
  export KUBECONFIG=\$HOME/.kube/config_new-autopilot
  kubectl -n kube-system get pods -l k8s-app=konnectivity-agent

기대: Running. 이후 kubectl logs / exec 가 정상 동작합니다.
EOF

log "11-firewall 완료"
