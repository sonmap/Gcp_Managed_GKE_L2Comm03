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
run-gke.sh
   ↓
client_gke
   ├─ ~/.kube/config_new-autopilot
   ├─ Namespace / KSA 확인
   ├─ NFS PV 생성/재사용
   ├─ NFS PVC 생성/재사용
   └─ Pod 생성
        ↓
GKE Autopilot Pod
   ├─ /mnt/l2comm ← NFS mount
   └─ Python BigQuery sample 실행
```

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

DOCKER_IMAGE=asia-northeast3-docker.pkg.dev/gcp-prod-edp-edge-509423/ar-l2comm-python/python-bq-batch:v1 \
/ssw/dlk/run-gke.sh \
  20261008 20261008 20261008 180000 \
  0 4 16 \
  /mnt/l2comm/python \
  python bq_sample.py
```

## 5. 실제 실행

```bash
unset DRY_RUN

DOCKER_IMAGE=asia-northeast3-docker.pkg.dev/gcp-prod-edp-edge-509423/ar-l2comm-python/python-bq-batch:v1 \
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
