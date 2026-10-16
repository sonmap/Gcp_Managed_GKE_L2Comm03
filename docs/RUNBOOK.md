# L2Comm03 테스트 런북

구축부터 배치 실행·결과 확인까지 단계별 명령어입니다.
각 단계마다 **확인 명령**과 **기대 결과**가 붙어 있으니, 기대 결과가 나오지 않으면
다음 단계로 넘어가지 마십시오.

전제:

| 계정 | 용도 | 사용 단계 |
|---|---|---|
| `admin@sonmap.net` | Owner. **권한 부여 전용** | 1단계 (`00-bootstrap.sh`)만 |
| `cho@sonmap.net` | 배포/운영 주체 | 2단계 이후 전부 |

- 0~4단계는 어디서든 가능, **5~7단계는 VPC 내부 VM에서만** 가능 (Private endpoint)
- 각 스크립트는 시작 시 실행 계정을 검증하고, 틀리면 전환 방법을 안내하며 중단합니다.
  우회하려면 `SKIP_ACCOUNT_CHECK=1`.

---

## 0. 사전 준비

### 0-1. 두 계정 로그인

```bash
gcloud auth login admin@sonmap.net    # Owner (권한 부여용)
gcloud auth login cho@sonmap.net      # 배포 주체
gcloud auth list
```

기대: 두 계정 모두 목록에 보임. 이후 `gcloud config set account` 로 전환합니다.

```bash
gcloud config set project gcp-prod-edp-edge-509423
gcloud config list
```

### 0-1b. 저장소

```bash
git clone https://github.com/sonmap/Gcp_Managed_GKE_L2Comm03.git
cd Gcp_Managed_GKE_L2Comm03
chmod +x gcloud/*.sh ssw/dlk/run-gke.sh ssw/dlk/client_gke
```

### 0-2. 변수 확인 (가장 중요)

```bash
cat gcloud/00-env.sh
```

프로젝트 ID, CIDR, SA 값이 실제 환경과 맞는지 확인하고 필요하면 수정합니다.

```bash
source gcloud/00-env.sh
echo "EDGE      : ${EDGE_PROJECT} (${EDGE_PROJECT_NUMBER})"
echo "HOST      : ${HOST_PROJECT}"
echo "DATA      : ${DATA_PROJECT}"
echo "OWNER     : ${OWNER_USER}   (권한 부여 전용)"
echo "ADMIN     : ${ADMIN_USER}   (배포 주체)"
echo "SA_GKE    : ${SA_GKE}"
echo "IMAGE     : ${IMAGE_URI}"
echo "VM_SA     : ${VM_SA}"
echo "NODE_SA   : ${AUTOPILOT_NODE_SA}"
```

기대: 모든 값이 출력되고 오류가 없음.

> `VM_SA`(620081195575-)와 `AUTOPILOT_NODE_SA`(541022739403-)의 프로젝트 번호가
> 서로 다릅니다. 위에 출력된 `EDGE_PROJECT_NUMBER`와 대조해 둘 중 어느 쪽이
> 맞는지 확인하십시오.

### 0-3. 권한 확인 (1단계 실행 후)

아래는 `00-bootstrap.sh` 가 끝난 뒤 배포 주체가 Role 을 제대로 받았는지
확인하는 명령입니다. 최초 구축 시에는 1단계 이후에 실행하십시오.

```bash
gcloud projects get-iam-policy gcp-prod-edp-edge-509423 \
  --flatten="bindings[].members" \
  --filter="bindings.members:cho@sonmap.net" \
  --format="value(bindings.role)"
```

```bash
gcloud projects get-iam-policy gcp-prod-edp-hub-vpchost \
  --flatten="bindings[].members" \
  --filter="bindings.members:cho@sonmap.net" \
  --format="value(bindings.role)"
```

Host 프로젝트에 `roles/compute.networkAdmin` 과 `roles/artifactregistry.admin`
이 없으면 2단계가 실패합니다.
Shared VPC 연결에는 조직 수준 `roles/compute.xpnAdmin` 이 추가로 필요하며,
이는 Owner 계정이 조직 수준에서 부여해야 합니다.

---

## 1. 00-bootstrap — API / IAM  (**Owner 계정**)

이 단계만 Owner 로 실행합니다. 하는 일은 API 활성화와 IAM 부여뿐입니다.

```bash
gcloud config set account admin@sonmap.net
gcloud config get-value account      # admin@sonmap.net 확인

./gcloud/00-bootstrap.sh
```

> 계정이 다르면 스크립트가 전환 방법을 안내하고 중단합니다.

완료 후 배포 주체로 전환합니다.

```bash
gcloud config set account cho@sonmap.net
gcloud config get-value account      # cho@sonmap.net 확인
```

이후 모든 단계는 이 계정으로 수행합니다.

### 확인

```bash
gcloud services list --enabled --project=gcp-prod-edp-edge-509423 \
  --filter="config.name:(container.googleapis.com OR cloudbuild.googleapis.com OR artifactregistry.googleapis.com OR bigquery.googleapis.com)" \
  --format="value(config.name)"
```

기대: 4개 모두 출력.

```bash
gcloud services list --enabled --project=gcp-prod-edp-edge-509423 \
  --filter="config.name:(workflows.googleapis.com OR cloudscheduler.googleapis.com)" \
  --format="value(config.name)"
```

기대: **아무것도 출력되지 않음** (L2Comm03은 Workflows/Scheduler 미사용).
이전에 L2Comm02를 구축했다면 남아 있을 수 있으며, 그대로 두어도 무방합니다.

---

## 2. 10-network — Shared VPC / Subnet  (**배포 주체**)

### 2-1. CIDR 중복 사전 확인

```bash
gcloud compute networks subnets list \
  --project=gcp-prod-edp-hub-vpchost \
  --regions=asia-northeast3 \
  --format="table(name, ipCidrRange, secondaryIpRanges[].ipCidrRange)"
```

아래 대역이 겹치지 않는지 확인합니다.

```text
10.252.1.0/24      Node
100.64.128.0/19    Pod
10.254.5.0/28      Control Plane
```

### 2-2. 실행

```bash
./gcloud/10-network.sh
```

> 스크립트가 CIDR 목록을 보여준 뒤 Enter 입력을 기다립니다.

### 확인

```bash
gcloud compute networks subnets describe subnet-prod-edp-l2comm-gke-an3 \
  --project=gcp-prod-edp-hub-vpchost \
  --region=asia-northeast3 \
  --format="yaml(name, ipCidrRange, secondaryIpRanges, privateIpGoogleAccess)"
```

기대:

```text
ipCidrRange: 10.252.1.0/24
secondaryIpRanges:
- ipCidrRange: 100.64.128.0/19
  rangeName: pods-prod-edp-l2comm-an3
privateIpGoogleAccess: true
```

Secondary Range는 **Pod 1개만** 있어야 합니다 (Service Range 없음).

```bash
gcloud compute shared-vpc associated-projects list gcp-prod-edp-hub-vpchost \
  --format="value(id)" | grep gcp-prod-edp-edge-509423
```

기대: 프로젝트 ID 출력.

---

## 3. 20-source-connection — Cloud Build 저장소 연결  (**배포 주체**)

```bash
gcloud builds connections list \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3
```

기대: `github-l2comm` 이 `COMPLETE` 상태.

```bash
./gcloud/20-source-connection.sh
```

### 확인

```bash
gcloud builds repositories list \
  --connection=github-l2comm \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3 \
  --format="table(name.basename(), remoteUri)"
```

기대: `Gcp_Managed_GKE_L2Comm03` 과 그 remote URI 가 보임.

---

## 4. 30-platform — AR / SA / Trigger / GKE  (**배포 주체**)

```bash
./gcloud/30-platform.sh
```

> GKE Autopilot 생성에 15~25분이 걸립니다. 중간에 끊지 마십시오.
> 마지막에 Namespace/KSA 생성은 VPC 외부라면 `SKIP` 으로 지나갑니다 (정상).

### 4-1. Artifact Registry (Host 프로젝트)

```bash
gcloud artifacts repositories list \
  --project=gcp-prod-edp-hub-vpchost --location=asia-northeast3 \
  --format="table(name.basename(), format)"
```

기대: `ar-l2comm-python`, `ar-l2comm-helm` (둘 다 DOCKER).

저장소 레벨 IAM이 핵심입니다. AR이 Host 프로젝트에 있어 Edge 프로젝트의
project IAM으로는 닿지 않습니다.

```bash
gcloud artifacts repositories get-iam-policy ar-l2comm-python \
  --project=gcp-prod-edp-hub-vpchost --location=asia-northeast3 \
  --format="yaml(bindings)"
```

기대:

```text
roles/artifactregistry.writer : sa-l2comm-gke@gcp-prod-edp-edge-509423...
roles/artifactregistry.reader : 541022739403-compute@... (Autopilot Node SA)
                                620081195575-compute@... (VM SA)
                                user:cho@sonmap.net
```

### 4-2. 통합 서비스 계정

```bash
gcloud iam service-accounts describe \
  sa-l2comm-gke@gcp-prod-edp-edge-509423.iam.gserviceaccount.com \
  --project=gcp-prod-edp-edge-509423
```

```bash
gcloud projects get-iam-policy gcp-prod-edp-edge-509423 \
  --flatten="bindings[].members" \
  --filter="bindings.members:sa-l2comm-gke@" \
  --format="value(bindings.role)"
```

기대 (Edge 프로젝트에 4개):

```text
roles/bigquery.jobUser
roles/compute.viewer
roles/logging.logWriter
roles/storage.objectViewer
```

> `roles/workflows.invoker`, `roles/container.developer` 가 **없어야** 정상입니다.
> `roles/artifactregistry.writer` 도 여기에는 없습니다 — AR이 Host 프로젝트에
> 있으므로 저장소 레벨로 부여되며, 4-1에서 확인합니다.

### 4-3. Job 생성 주체 권한

```bash
gcloud projects get-iam-policy gcp-prod-edp-edge-509423 \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/container.developer" \
  --format="value(bindings.members)"
```

기대: `user:cho@sonmap.net` 과 VM SA 가 포함.

### 4-4. BigQuery Dataset 권한

```bash
bq show --format=prettyjson pjt-c-admin:dlk_sample | grep -A3 sa-l2comm-gke
```

기대: `"role": "WRITER"` 또는 `roles/bigquery.dataEditor` 항목에 통합 SA.

### 4-5. Workload Identity 바인딩

```bash
gcloud iam service-accounts get-iam-policy \
  sa-l2comm-gke@gcp-prod-edp-edge-509423.iam.gserviceaccount.com \
  --project=gcp-prod-edp-edge-509423 \
  --format="yaml(bindings)"
```

기대: `roles/iam.workloadIdentityUser` 에
`serviceAccount:gcp-prod-edp-edge-509423.svc.id.goog[l2comm-batch/ksa-l2comm-batch]`

### 4-6. GKE 클러스터

```bash
gcloud container clusters describe gke-l2comm-batch-an3 \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3 \
  --format="yaml(name, status, autopilot.enabled, network, subnetwork,
                 ipAllocationPolicy.clusterSecondaryRangeName,
                 ipAllocationPolicy.servicesIpv4Cidr,
                 privateClusterConfig.masterIpv4CidrBlock,
                 privateClusterConfig.enablePrivateEndpoint,
                 workloadIdentityConfig.workloadPool)"
```

기대:

```text
status: RUNNING
autopilot.enabled: true
clusterSecondaryRangeName: pods-prod-edp-l2comm-an3
servicesIpv4Cidr: 34.118.224.0/20     <- GKE managed
masterIpv4CidrBlock: 10.254.5.0/28
enablePrivateEndpoint: true
workloadPool: gcp-prod-edp-edge-509423.svc.id.goog
```

### 4-7. Cloud Build Trigger

```bash
gcloud builds triggers describe trg-l2comm-python-image \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3 \
  --format="yaml(name, filename, serviceAccount, includedFiles,
                 repositoryEventConfig.repository,
                 repositoryEventConfig.push.branch)"
```

기대: `includedFiles` 에 `gcloud/**` 포함, `serviceAccount` 가 `sa-l2comm-gke`.

---

## 5. 이미지 빌드 테스트

### 5-1. 수동 빌드 (Trigger 실행)

```bash
gcloud builds triggers run trg-l2comm-python-image \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3 \
  --branch=main
```

### 5-2. 빌드 상태 확인

```bash
gcloud builds list \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3 \
  --limit=5 --format="table(id, status, createTime, duration)"
```

기대: 최신 빌드가 `SUCCESS`. `WORKING` 이면 몇 분 대기.

실패 시 로그:

```bash
BUILD_ID=$(gcloud builds list --project=gcp-prod-edp-edge-509423 \
  --region=asia-northeast3 --limit=1 --format="value(id)")

gcloud builds log "${BUILD_ID}" \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3
```

### 5-3. 이미지 생성 확인

```bash
gcloud artifacts docker images list \
  asia-northeast3-docker.pkg.dev/gcp-prod-edp-hub-vpchost/ar-l2comm-python \
  --include-tags --format="table(package, tags, createTime)"
```

기대: `python-bq-batch` 에 `v1` 태그.

> Git push 로 자동 빌드되는지도 확인하려면 `app/` 아래 파일을 수정해
> main 에 push 한 뒤 5-2 를 다시 실행합니다.

---

## 6. VM 준비 (VPC 내부에서 실행)

여기서부터는 **VPC 내부 VM**에서 수행합니다.

### 6-1. 저장소 및 스크립트 배치

```bash
cd ~/Gcp_Managed_GKE_L2Comm03
git pull

bash ssw/dlk/install-vm.sh
```

### 6-2. NFS 서버 구성 (PoC)

```bash
sudo bash /ssw/dlk/setup-nfs-server.sh
```

확인:

```bash
showmount -e localhost
ls /mnt/python
```

기대: export 목록과 `bq_sample.py`, `requirements.txt`.

### 6-3. 클러스터 자격증명

```bash
gcloud container clusters get-credentials gke-l2comm-batch-an3 \
  --project=gcp-prod-edp-edge-509423 \
  --region=asia-northeast3 \
  --internal-ip
```

`client_gke` 는 기본적으로 `$HOME/.kube/config_new-autopilot` 를 봅니다.

```bash
KUBECONFIG=$HOME/.kube/config_new-autopilot \
gcloud container clusters get-credentials gke-l2comm-batch-an3 \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3 --internal-ip
```

확인:

```bash
export KUBECONFIG=$HOME/.kube/config_new-autopilot
kubectl get nodes
kubectl cluster-info
```

기대: Control Plane 응답. 타임아웃이면 VPC 라우팅/방화벽 문제입니다.

### 6-4. Namespace / KSA

```bash
kubectl get ns l2comm-batch
kubectl -n l2comm-batch get serviceaccount ksa-l2comm-batch -o yaml
```

기대: 어노테이션에
`iam.gke.io/gcp-service-account: sa-l2comm-gke@gcp-prod-edp-edge-509423.iam.gserviceaccount.com`

없으면 직접 생성:

```bash
kubectl create namespace l2comm-batch
kubectl -n l2comm-batch create serviceaccount ksa-l2comm-batch
kubectl -n l2comm-batch annotate serviceaccount ksa-l2comm-batch \
  iam.gke.io/gcp-service-account=sa-l2comm-gke@gcp-prod-edp-edge-509423.iam.gserviceaccount.com \
  --overwrite
```

---

## 7. 배치 실행 테스트

### 7-1. DRY_RUN — 매니페스트만 확인

```bash
cd ~/Gcp_Managed_GKE_L2Comm03

DOCKER_IMAGE=asia-northeast3-docker.pkg.dev/gcp-prod-edp-hub-vpchost/ar-l2comm-python/python-bq-batch:v1 \
./ssw/dlk/run-gke.sh \
  20261016 20261016 20261016 180000 \
  0 4 16 \
  /mnt/l2comm/python \
  python bq_sample.py
```

기대: 파라미터 10개가 출력되고 `pv.yaml` / `pvc.yaml` / `job.yaml` 이 표시됨.
`job.yaml` 에서 확인할 것:

```text
kind: Job
apiVersion: batch/v1
backoffLimit: 1
ttlSecondsAfterFinished: 600
serviceAccountName: ksa-l2comm-batch
image: ...python-bq-batch:v1
cpu "4" / memory "16Gi"
mountPath: /mnt/l2comm
```

> 파라미터를 9개만 주면 usage 가 출력되고 종료됩니다. 계약 검증용으로
> 한 번 확인해 보십시오.

### 7-2. 실제 실행

```bash
DRY_RUN=0 \
DOCKER_IMAGE=asia-northeast3-docker.pkg.dev/gcp-prod-edp-hub-vpchost/ar-l2comm-python/python-bq-batch:v1 \
./ssw/dlk/run-gke.sh \
  20261016 20261016 20261016 180000 \
  0 4 16 \
  /mnt/l2comm/python \
  python bq_sample.py
```

기대 흐름:

```text
[INFO] PVC status        -> Bound
[INFO] Waiting for Job completion: l2comm-...
job.batch/l2comm-... condition met
================ JOB LOG ================
Loading 43 GCP regions into pjt-c-admin.dlk_sample.gcp_region_inventory
Completed: pjt-c-admin.dlk_sample.gcp_region_inventory, rows=43
=========================================
[SUCCESS] l2comm-...
```

> Autopilot 은 Node 를 새로 띄우므로 첫 실행은 2~5분 걸릴 수 있습니다.

### 7-3. 실행 중 다른 터미널에서 관찰

```bash
export KUBECONFIG=$HOME/.kube/config_new-autopilot

kubectl -n l2comm-batch get jobs -w
kubectl -n l2comm-batch get pods -w
```

Pod 상세:

```bash
POD=$(kubectl -n l2comm-batch get pods \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')

kubectl -n l2comm-batch describe pod "${POD}"
kubectl -n l2comm-batch logs "${POD}" -f
```

### 7-4. Job 보존하며 실행 (디버깅용)

```bash
KEEP_JOB=1 DRY_RUN=0 \
DOCKER_IMAGE=asia-northeast3-docker.pkg.dev/gcp-prod-edp-hub-vpchost/ar-l2comm-python/python-bq-batch:v1 \
./ssw/dlk/run-gke.sh \
  20261016 20261016 20261016 180000 \
  0 4 16 \
  /mnt/l2comm/python \
  python bq_sample.py

kubectl -n l2comm-batch get jobs
```

---

## 8. 결과 확인

### 8-1. BigQuery 적재 건수

```bash
bq query --project_id=pjt-c-admin --use_legacy_sql=false \
  'SELECT COUNT(*) AS row_count
   FROM `pjt-c-admin.dlk_sample.gcp_region_inventory`'
```

기대: `row_count = 43`

### 8-2. 샘플 데이터

```bash
bq query --project_id=pjt-c-admin --use_legacy_sql=false \
  'SELECT * FROM `pjt-c-admin.dlk_sample.gcp_region_inventory` LIMIT 10'
```

### 8-3. 전체 상태 일괄 점검

```bash
cd ~/Gcp_Managed_GKE_L2Comm03
./gcloud/99-verify.sh
```

---

## 9. 자주 겪는 오류

| 증상 | 원인 | 조치 |
|---|---|---|
| `ALREADY_EXISTS` 로 중단 | 멱등 처리 누락 자원 | 스크립트는 대부분 `describe \|\| create`. 메시지의 자원명을 확인하고 기존 것을 그대로 사용 |
| `PERMISSION_DENIED` (subnet 생성) | Host 프로젝트 권한 부족 | `compute.networkAdmin`, 조직 `compute.xpnAdmin` 확인 |
| Cluster 생성 실패 | GKE Service Agent 권한 | `10-network.sh` 재실행 후 `container.hostServiceAgentUser` 확인 |
| `kubectl` 타임아웃 | VPC 외부에서 실행 | VPC 내부 VM 에서 `--internal-ip` 로 재인증 |
| Pod `ImagePullBackOff` | 크로스 프로젝트 AR 권한 | AR이 Host 프로젝트에 있으므로 **저장소 레벨** reader 필요 (4-1). `AUTOPILOT_NODE_SA` 값도 함께 확인 |
| Build 중 `denied: Permission ... artifactregistry.repositories.uploadArtifacts` | Build SA의 AR writer 누락 | Host 프로젝트 저장소에 `sa-l2comm-gke` writer 바인딩 확인 (4-1) |
| Pod 에서 BigQuery 403 | Workload Identity 미연결 | KSA 어노테이션과 `workloadIdentityUser` 바인딩 확인 (4-5, 6-4) |
| PVC `Pending` | NFS 서버 미기동 / IP 불일치 | VM 에서 `showmount -e localhost`, `--nfs-server` 로 IP 명시 |
| Job 생성 403 | 실행 주체 권한 | `container.developer` 가 실행 계정/VM SA 에 있는지 확인 (4-3) |
| 스크립트가 계정 오류로 중단 | 계정 분리 규칙 | `00-bootstrap.sh` 는 `admin@sonmap.net`, 나머지는 `cho@sonmap.net`. `gcloud config set account <계정>` 으로 전환 |
| 2단계 이후 권한 부족 | 1단계 미실행 또는 다른 계정으로 실행 | Owner 로 `00-bootstrap.sh` 재실행 후 0-3 으로 Role 확인 |

### 디버깅 명령

```bash
# Autopilot 이벤트
kubectl -n l2comm-batch get events --sort-by=.lastTimestamp | tail -20

# Workload Identity 실제 동작 확인 (Pod 내부에서)
kubectl -n l2comm-batch run wi-test --rm -it --restart=Never \
  --image=google/cloud-sdk:slim \
  --overrides='{"spec":{"serviceAccountName":"ksa-l2comm-batch"}}' \
  -- gcloud auth list
```

기대: `sa-l2comm-gke@...` 가 활성 계정으로 표시.

---

## 10. 정리

```bash
# Job 정리
kubectl -n l2comm-batch delete jobs --all

# 전체 자원 삭제 (각 단계 확인 프롬프트)
./gcloud/90-teardown.sh
```
