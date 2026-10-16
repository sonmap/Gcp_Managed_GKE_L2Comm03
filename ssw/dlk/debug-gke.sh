#!/usr/bin/env bash
set -Eeuo pipefail

# 배치와 동일한 환경의 디버그 Pod 를 띄우고 쉘로 접속합니다.
#
# 배치 Job 은 수십 초 만에 끝나고 삭제되므로 접속할 수 없습니다.
# 이 스크립트는 같은 이미지 / KSA / NFS 마운트로 대기 Pod 를 만들어
# kubectl exec 로 들어가게 해줍니다.
#
# 사용:
#   ./ssw/dlk/debug-gke.sh            # 생성 + 접속
#   ./ssw/dlk/debug-gke.sh delete     # 정리
#   ./ssw/dlk/debug-gke.sh shell      # 이미 떠 있는 Pod 에 재접속
#
# 환경변수:
#   KUBECONFIG   기본 $HOME/.kube/config_new-autopilot
#   POD_NAME     기본 l2comm-debug
#   NAMESPACE    기본 l2comm-batch
#   TIMEOUT      Ready 대기 초. 기본 300 (Autopilot 노드 기동에 2~5분)

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config_new-autopilot}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MANIFEST="${MANIFEST:-${REPO_ROOT}/k8s/debug-pod.yaml}"

POD_NAME="${POD_NAME:-l2comm-debug}"
NAMESPACE="${NAMESPACE:-l2comm-batch}"
TIMEOUT="${TIMEOUT:-300}"

ACTION="${1:-up}"

[[ -f "${MANIFEST}" ]] || { echo "ERROR: manifest 없음: ${MANIFEST}" >&2; exit 1; }

case "${ACTION}" in
  delete|down)
    kubectl delete -f "${MANIFEST}" --ignore-not-found=true
    echo "[OK] ${POD_NAME} 정리 완료"
    exit 0
    ;;
  shell|exec)
    exec kubectl -n "${NAMESPACE}" exec -it "${POD_NAME}" -- bash
    ;;
  up) ;;
  *)
    echo "Usage: $0 [up|shell|delete]" >&2
    exit 1
    ;;
esac

# 이미 떠 있으면 재사용
if kubectl -n "${NAMESPACE}" get pod "${POD_NAME}" >/dev/null 2>&1; then
  PHASE="$(kubectl -n "${NAMESPACE}" get pod "${POD_NAME}" -o jsonpath='{.status.phase}')"
  echo "[INFO] 기존 Pod 발견 (${PHASE})"
  if [[ "${PHASE}" != "Running" ]]; then
    echo "[INFO] Running 이 아니므로 재생성합니다."
    kubectl delete -f "${MANIFEST}" --ignore-not-found=true
    kubectl wait -n "${NAMESPACE}" --for=delete "pod/${POD_NAME}" --timeout=120s 2>/dev/null || true
    kubectl apply -f "${MANIFEST}"
  fi
else
  kubectl apply -f "${MANIFEST}"
fi

echo "[INFO] Ready 대기 (최대 ${TIMEOUT}s). Autopilot 노드 기동에 2~5분 걸릴 수 있습니다."
if ! kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${POD_NAME}" --timeout="${TIMEOUT}s"; then
  echo "[ERROR] Pod 가 Ready 가 되지 않았습니다." >&2
  kubectl -n "${NAMESPACE}" get pod "${POD_NAME}" -o wide || true
  kubectl -n "${NAMESPACE}" describe pod "${POD_NAME}" || true
  exit 1
fi

cat <<EOF

============================================================
접속합니다: ${NAMESPACE}/${POD_NAME}
============================================================
Pod 안에서 확인할 것들:

  pwd && ls -l                      # /app, main.py (이미지 내부)
  ls -l /mnt/l2comm/python/         # NFS 마운트 (Git mnt/)
  head -5 /mnt/l2comm/python/bq_sample.py
  env | grep TARGET                 # 주입된 환경변수
  python main.py                    # 적재 배치 수동 실행
  python /mnt/l2comm/python/bq_sample.py   # 조회 샘플

빠져나오기: exit
정리      : ./ssw/dlk/debug-gke.sh delete
(2시간 뒤 자동 종료됩니다)
============================================================

EOF

exec kubectl -n "${NAMESPACE}" exec -it "${POD_NAME}" -- bash
