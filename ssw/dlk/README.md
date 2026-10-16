# /ssw/dlk PoC 실행 구조

Repository의 `ssw/dlk` 디렉터리를 VM의 `/ssw/dlk`에 symlink하여 사용합니다.

## 구조

```text
GitHub
Gcp_Managed_GKE_L2Comm03
├─ ssw/dlk/
│  ├─ run-gke.sh
│  ├─ client_gke
│  ├─ install-vm.sh
│  └─ setup-nfs-server.sh
└─ mnt/
   └─ python/
      └─ bq_sample.py
```

실행 흐름:

```text
run-gke.sh  (파라미터 10개)
   ↓
client_gke
   ├─ ~/.kube/config_new-autopilot
   ├─ Namespace / KSA 확인
   ├─ NFS PV 생성/재사용
   ├─ NFS PVC 생성/재사용
   └─ GKE Job 생성 (batch/v1)
        ↓
GKE Autopilot Job → Pod
   ├─ Artifact Registry Image Pull (기존 이미지 재사용)
   ├─ /mnt/l2comm ← NFS mount
   └─ Python BigQuery sample 실행
        ↓
   kubectl wait --for=condition=complete → 로그 출력 → Job 정리
```

> Cloud Workflows / Cloud Scheduler를 거치지 않습니다. `client_gke`가 GKE API로
> Job을 직접 생성하고 완료까지 대기합니다.

파라미터 계약 (10개):

| # | 파라미터 | 예시 |
|---|---|---|
| 1 | `FROM_BASE_YMD` | `20261016` |
| 2 | `TO_BASE_YMD` | `20261016` |
| 3 | `CURR_YMD` | `20261016` |
| 4 | `CURR_TIME` | `180000` |
| 5 | `VM_GPU` | `0` |
| 6 | `VM_CPU` | `4` |
| 7 | `VM_MEM` (GiB) | `16` |
| 8 | `WORKING_DIRECTORY` | `/mnt/l2comm/python` |
| 9 | `PROGRAM_PATH` | `python` |
| 10 | `PROGRAM_PARAM` | `bq_sample.py` |

실행 예시:

```bash
DRY_RUN=0 \
DOCKER_IMAGE=asia-northeast3-docker.pkg.dev/gcp-prod-edp-hub-vpchost/ar-l2comm-python/python-bq-batch:v1 \
/ssw/dlk/run-gke.sh \
  20261016 20261016 20261016 180000 \
  0 4 16 \
  /mnt/l2comm/python \
  python bq_sample.py
```

`DRY_RUN`을 생략하면 기본값 `1`이라 매니페스트만 출력하고 apply하지 않습니다.
Job 동작 제어 환경변수: `BACKOFF_LIMIT`(1), `TTL_SECONDS`(600), `JOB_TIMEOUT`(3600),
`KEEP_JOB=1`(완료 후 Job 보존).

## 1. VM에 /ssw/dlk 연결

```bash
cd ~/Gcp_Managed_GKE_L2Comm03
git pull

bash ssw/dlk/install-vm.sh
```

확인:

```bash
ls -l /ssw/dlk
```

## 2. VM을 PoC NFS 서버로 구성

```bash
sudo bash /ssw/dlk/setup-nfs-server.sh
```

이 구성은 Repository의 `mnt/`를 NFSv4로 read-only export합니다.

GKE Pod CIDR:

```text
100.64.128.0/19
```

에서 VM의 TCP/2049 접근이 허용되어야 합니다.

Shared VPC Host에서 방화벽 예시:

```bash
gcloud compute firewall-rules create allow-l2comm-gke-to-nfs \
  --project=gcp-prod-edp-hub-vpchost \
  --network=vpc-prod-edp-hub \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:2049 \
  --source-ranges=100.64.128.0/19
```

가능하면 실제 NFS VM에만 적용되도록 target tag 또는 target service account를 추가하세요.

## 3. NFS 확인

VM:

```bash
sudo exportfs -v
sudo ss -lntp | grep 2049
```

## 4. YAML만 생성

```bash
export KUBECONFIG="$HOME/.kube/config_new-autopilot"
export DRY_RUN=1

DOCKER_IMAGE=asia-northeast3-docker.pkg.dev/gcp-prod-edp-hub-vpchost/ar-l2comm-python/python-bq-batch:v1 \
/ssw/dlk/run-gke.sh \
  20261008 20261008 20261008 180000 \
  0 4 16 \
  /mnt/l2comm/python \
  python bq_sample.py
```

## 5. 실제 실행

```bash
unset DRY_RUN

DOCKER_IMAGE=asia-northeast3-docker.pkg.dev/gcp-prod-edp-hub-vpchost/ar-l2comm-python/python-bq-batch:v1 \
/ssw/dlk/run-gke.sh \
  20261008 20261008 20261008 180000 \
  0 4 16 \
  /mnt/l2comm/python \
  python bq_sample.py
```

## Kubernetes Storage

`client_gke`가 다음을 생성/재사용합니다.

```text
PV  : l2comm-git-nfs-pv
PVC : l2comm-git-nfs-pvc
Mode: ReadOnlyMany
NFS : <VM internal IP>:/
Pod : /mnt/l2comm
```

Autopilot에서는 NFS 및 PersistentVolumeClaim volume type을 사용할 수 있습니다.

## 운영 권고

현재 VM의 root disk는 약 29GB 수준이므로 이 NFS 방식은 PoC/기능검증용입니다.
운영 전환에서는 Filestore + Filestore CSI Driver 기반 RWX PV/PVC 구성을 권장합니다.
