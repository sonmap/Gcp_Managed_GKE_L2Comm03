# L2Comm03 RUNBOOK (Ubuntu VM 작업 기준)

VPC 내부 Ubuntu VM 한 대에서 `git clone` 부터 배치 실행·결과 확인까지
전부 수행하는 절차입니다. 위에서부터 순서대로 복사해 실행하십시오.

각 단계는 **실행 → 확인 → 기대 결과** 구성입니다.
기대 결과가 나오지 않으면 다음 단계로 넘어가지 말고 §13(오류 대응)를 보십시오.

---

## 계정 분리 원칙

| 계정 | 용도 | 사용 단계 |
|---|---|---|
| `admin@sonmap.net` | Owner. **권한(IAM) 부여 + 네트워크 관리** | §4, §5, §10-3 |
| `cho@sonmap.net` | 배포·운영 주체 | §6 이후 전부 (§6-2 권한 사전 점검 필수) |

각 스크립트는 시작 시 실행 계정을 검증하고, 틀리면 전환 방법을 안내하며 중단합니다.
우회가 필요하면 `SKIP_ACCOUNT_CHECK=1` 을 앞에 붙입니다.

## VM 요구사항

- Ubuntu 20.04 / 22.04 / 24.04
- **Shared VPC `vpc-prod-edp-hub` 내부**에 위치 (Private endpoint 접근 때문)
- 인터넷 egress 가능 (패키지 설치, GitHub clone)
- sudo 권한

---

## 1. VM 기본 패키지 설치

```bash
sudo apt-get update
sudo apt-get install -y git curl apt-transport-https ca-certificates gnupg
```

### 확인

```bash
git --version
```

기대: `git version 2.x.x`

---

## 2. gcloud CLI 설치

이미 설치되어 있으면 건너뜁니다.

```bash
gcloud version
```

`command not found` 이면 아래를 실행합니다.

```bash
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg

echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list

sudo apt-get update
sudo apt-get install -y google-cloud-cli
```

### 확인

```bash
gcloud version
```

기대: `Google Cloud SDK 5xx.x.x` 등 버전 출력.

---

## 3. kubectl 및 GKE 인증 플러그인 설치

GKE 접속에는 `gke-gcloud-auth-plugin` 이 **반드시** 필요합니다.

```bash
sudo apt-get install -y kubectl google-cloud-cli-gke-gcloud-auth-plugin
```

### 확인

```bash
kubectl version --client
gke-gcloud-auth-plugin --version
```

기대: 두 명령 모두 버전 출력.

```bash
echo 'export USE_GKE_GCLOUD_AUTH_PLUGIN=True' >> ~/.bashrc
source ~/.bashrc
```

---

## 4. Owner 계정으로 권한 부여  (**Owner 계정**)

### 4-1. Owner 로그인

VM 에는 브라우저가 없으므로 `--no-launch-browser` 를 사용합니다.
출력된 URL 을 PC 브라우저에서 열고, 받은 인증 코드를 터미널에 붙여 넣습니다.

```bash
gcloud auth login admin@sonmap.net --no-launch-browser
```

### 4-2. 배포 주체 계정도 미리 로그인

```bash
gcloud auth login cho@sonmap.net --no-launch-browser
```

### 확인

```bash
gcloud auth list
```

기대: 두 계정이 모두 목록에 표시됨.

### 4-3. 저장소 clone

```bash
cd ~
git clone https://github.com/sonmap/Gcp_Managed_GKE_L2Comm03.git
cd ~/Gcp_Managed_GKE_L2Comm03
chmod +x gcloud/*.sh ssw/dlk/run-gke.sh ssw/dlk/client_gke ssw/dlk/install-vm.sh
```

### 확인

```bash
ls -l gcloud/
```

기대: `00-env.sh`, `00-bootstrap.sh`, `10-network.sh`, `20-source-connection.sh`,
`30-platform.sh`, `90-teardown.sh`, `99-verify.sh` 가 실행 권한(`-rwxr-xr-x`)으로 존재.

### 4-4. 변수 확인 (가장 중요)

```bash
vi gcloud/00-env.sh
```

프로젝트 ID, CIDR, 계정, SA 값이 실제 환경과 맞는지 확인하고 필요하면 수정합니다.

```bash
gcloud config set account admin@sonmap.net
gcloud config set project gcp-prod-edp-edge-509423

source gcloud/00-env.sh
echo "EDGE    : ${EDGE_PROJECT} (${EDGE_PROJECT_NUMBER})"
echo "HOST    : ${HOST_PROJECT}"
echo "DATA    : ${DATA_PROJECT}"
echo "AR      : ${AR_PROJECT}"
echo "OWNER   : ${OWNER_USER}"
echo "ADMIN   : ${ADMIN_USER}"
echo "SA_GKE  : ${SA_GKE}"
echo "IMAGE   : ${IMAGE_URI}"
echo "VM_SA   : ${VM_SA}"
echo "NODE_SA : ${AUTOPILOT_NODE_SA}"
```

기대: 모든 값이 출력되고 오류가 없음.

> `VM_SA`(620081195575-)와 `AUTOPILOT_NODE_SA`(541022739403-)의 프로젝트 번호가
> 서로 다릅니다. 위에 출력된 `EDGE_PROJECT_NUMBER` 와 대조해 어느 쪽이 맞는지
> 확인하고, 틀리면 `00-env.sh` 를 수정하십시오.

이 VM 자신의 서비스 계정도 확인합니다.

```bash
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email
echo
```

기대: 출력값이 `00-env.sh` 의 `VM_SA` 와 일치.

### 4-5. 00-bootstrap 실행

```bash
gcloud config get-value account
```

기대: `admin@sonmap.net`

```bash
./gcloud/00-bootstrap.sh
```

VM 기본 SA 로도 gcloud 를 돌릴 예정이면:

```bash
GRANT_VM_DEPLOYER=true ./gcloud/00-bootstrap.sh
```

### 확인

```bash
gcloud services list --enabled --project=gcp-prod-edp-edge-509423 \
  --filter="config.name:(container.googleapis.com OR cloudbuild.googleapis.com OR bigquery.googleapis.com)" \
  --format="value(config.name)"
```

기대: 3개 모두 출력.

```bash
gcloud services list --enabled --project=gcp-prod-edp-hub-vpchost \
  --filter="config.name:artifactregistry.googleapis.com" \
  --format="value(config.name)"
```

기대: `artifactregistry.googleapis.com` (AR 이 Host 프로젝트에 있음).

```bash
gcloud projects get-iam-policy gcp-prod-edp-edge-509423 \
  --flatten="bindings[].members" \
  --filter="bindings.members:cho@sonmap.net" \
  --format="value(bindings.role)"
```

기대 (7개): `cloudbuild.builds.editor`, `compute.viewer`, `container.admin`,
`iam.serviceAccountAdmin`, `iam.serviceAccountUser`,
`resourcemanager.projectIamAdmin`, `serviceusage.serviceUsageAdmin`

```bash
gcloud projects get-iam-policy gcp-prod-edp-hub-vpchost \
  --flatten="bindings[].members" \
  --filter="bindings.members:cho@sonmap.net" \
  --format="value(bindings.role)"
```

기대 (2개): `artifactregistry.admin`, `serviceusage.serviceUsageAdmin`

> 네트워크 관리(`compute.networkAdmin` / `securityAdmin`)는 Owner 영역이므로
> 배포 주체에게 부여하지 않습니다. GKE 생성에 필요한 Subnet 접근은
> §5-6 에서 해당 Subnet 한정으로 `compute.networkUser` 가 부여됩니다.

### 4-6. 조직 수준 권한 확인 (Shared VPC 연결용)

Shared VPC 서비스 프로젝트 연결에는 조직 수준 권한이 필요하며,
이는 프로젝트 IAM 이 아니라 스크립트가 부여하지 못합니다.

Owner 계정이 조직 수준 `compute.xpnAdmin` 을 이미 보유하고 있다면 추가 작업이
없습니다. §5 는 Owner 로 실행하므로 배포 주체에게 이 권한을 위임할 필요가 없습니다.

확인:

```bash
gcloud organizations list
```

```bash
ORG_ID=<위에서 확인한 ID>

gcloud organizations get-iam-policy "${ORG_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.members:admin@sonmap.net AND bindings.role:roles/compute.xpnAdmin" \
  --format="value(bindings.role)"
```

기대: `roles/compute.xpnAdmin` 출력 (또는 Owner 가 조직 Owner 여서 포함).
출력이 없고 Shared VPC 연결도 아직이면, 조직 관리자가 Owner 계정에
`roles/compute.xpnAdmin` 을 부여해야 §5-4 가 성공합니다.

---

## 5. 네트워크 구성  (**Owner 계정 계속**)

Shared VPC 연결, Host 프로젝트 Subnet 생성, Subnet/Project 레벨 IAM 부여는
모두 네트워크 관리 영역이므로 Owner 계정으로 수행합니다.

### 5-1. 계정 확인

```bash
gcloud config get-value account
```

기대: `admin@sonmap.net` (§4 에서 이미 전환된 상태)

### 5-2. CIDR 중복 사전 확인

```bash
gcloud compute networks subnets list \
  --project=gcp-prod-edp-hub-vpchost \
  --regions=asia-northeast3 \
  --format="table(name, ipCidrRange, secondaryIpRanges[].ipCidrRange)"
```

아래 대역과 겹치는 것이 없어야 합니다.

```text
10.252.1.0/24      Node
100.64.128.0/19    Pod
10.254.5.0/28      Control Plane
```

### 5-3. Shared VPC 연결 여부 확인

```bash
gcloud compute shared-vpc associated-projects list gcp-prod-edp-hub-vpchost \
  --format="value(id)" | grep gcp-prod-edp-edge-509423
```

출력이 있으면 이미 연결된 상태입니다 (4-6 생략 가능).

### 5-4. 10-network 실행 (Owner)

```bash
cd ~/Gcp_Managed_GKE_L2Comm03
./gcloud/10-network.sh
```

> CIDR 목록을 보여준 뒤 Enter 입력을 기다립니다. 확인 후 Enter.

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

Secondary Range 는 **Pod 1개만** 있어야 합니다 (Service Range 없음).

### 5-6. Subnet 레벨 IAM 확인

```bash
gcloud compute networks subnets get-iam-policy subnet-prod-edp-l2comm-gke-an3 \
  --project=gcp-prod-edp-hub-vpchost --region=asia-northeast3 \
  --format="yaml(bindings)"
```

기대: `roles/compute.networkUser` 에 아래 4개.

```text
serviceAccount:service-<EDGE번호>@container-engine-robot.iam.gserviceaccount.com
serviceAccount:<EDGE번호>@cloudservices.gserviceaccount.com
user:cho@sonmap.net
serviceAccount:<VM_SA>
```

> 배포 주체에게 Host 프로젝트 전체 네트워크 권한을 주지 않고, 이 Subnet 에만
> 한정해 부여합니다. 이것이 있어야 §8 에서 GKE 생성이 가능합니다.

---

## 6. 배포 주체 전환 및 권한 사전 점검  (**배포 주체**)

### 6-1. 계정 전환

여기서부터 배포 주체 계정으로 전환합니다.

```bash
gcloud config set account cho@sonmap.net
gcloud config get-value account
```

기대: `cho@sonmap.net`

### 6-2. 권한 사전 점검 (중요)

20 단계 이후에 필요한 권한을 미리 확인합니다. 여기서 걸러내지 않으면
작업 도중 `PERMISSION_DENIED` 로 멈춥니다.

```bash
cd ~/Gcp_Managed_GKE_L2Comm03
./gcloud/05-check-permissions.sh
```

기대: 모든 항목 `OK`, 마지막에 `점검 통과` 메시지.

`FAIL` 이 있으면 어떤 Role 이 빠졌는지 표시됩니다. Owner 로 되돌아가
재실행한 뒤 다시 점검합니다.

```bash
gcloud config set account admin@sonmap.net
./gcloud/00-bootstrap.sh
./gcloud/10-network.sh            # Subnet 항목이 FAIL 인 경우
gcloud config set account cho@sonmap.net
./gcloud/05-check-permissions.sh
```

---

## 7. Cloud Build 저장소 연결  (**배포 주체**)

기존 `github-l2comm` Connection 에는 `Gcp_Managed_GKE_L2Comm` 과
`Gcp_Managed_GKE_L2Comm02` 만 연결되어 있습니다. **Connection 은 재사용**하고
그 아래에 `Gcp_Managed_GKE_L2Comm03` 저장소만 **추가**합니다.
Connection 을 새로 만들 필요는 없습니다.

### 7-1. Connection 확인

```bash
gcloud builds connections list \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3 \
  --format="table(name.basename(), installationState.stage)"
```

기대: `github-l2comm` 이 `COMPLETE`.

현재 연결된 저장소 목록:

```bash
gcloud builds repositories list \
  --connection=github-l2comm \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3 \
  --format="table(name.basename(), remoteUri)"
```

이 시점에는 `L2Comm`, `L2Comm02` 두 개만 보입니다.

### 7-2. GitHub App 접근 권한 확인 (선행 조건)

Cloud Build GitHub App 이 **Only select repositories** 로 설치되어 있으면,
GitHub 쪽에서 `Gcp_Managed_GKE_L2Comm03` 을 먼저 허용해야 7-3 이 성공합니다.

브라우저에서 확인합니다.

```text
https://github.com/settings/installations
  또는 조직 계정이면
https://github.com/organizations/sonmap/settings/installations
```

`Google Cloud Build` → **Configure** → Repository access 에서
`Gcp_Managed_GKE_L2Comm03` 이 포함되어 있는지 확인하고, 없으면 추가합니다.
(`All repositories` 로 설정되어 있으면 이 단계는 불필요합니다.)

> 이 단계를 건너뛰면 7-3 에서 저장소를 찾지 못하거나
> `PERMISSION_DENIED` / `NOT_FOUND` 가 발생합니다.

### 7-3. 저장소 추가 실행

```bash
./gcloud/20-source-connection.sh
```

> 스크립트는 멱등입니다. 이미 연결되어 있으면 `SKIP (이미 연결됨)` 을 출력하고
> 재생성하지 않습니다. 기존 `L2Comm` / `L2Comm02` 연결에도 영향을 주지 않습니다.

### 확인

```bash
gcloud builds repositories list \
  --connection=github-l2comm \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3 \
  --format="table(name.basename(), remoteUri)"
```

기대: 기존 2개에 더해 `Gcp_Managed_GKE_L2Comm03` 이 추가되어 **3개**가 보임.

```text
Gcp_Managed_GKE_L2Comm     https://github.com/sonmap/Gcp_Managed_GKE_L2Comm.git
Gcp_Managed_GKE_L2Comm02   https://github.com/sonmap/Gcp_Managed_GKE_L2Comm02.git
Gcp_Managed_GKE_L2Comm03   https://github.com/sonmap/Gcp_Managed_GKE_L2Comm03.git
```

---

## 8. 플랫폼 구성 (AR / SA / Trigger / GKE)  (**배포 주체**)

```bash
./gcloud/30-platform.sh
```

> GKE Autopilot 생성에 **15~25분** 걸립니다. 중간에 끊지 마십시오.
> SSH 가 끊길 염려가 있으면 `tmux` 또는 `screen` 안에서 실행하십시오.
>
> ```bash
> sudo apt-get install -y tmux
> tmux new -s l2comm
> ./gcloud/30-platform.sh
> # 분리: Ctrl+b 누른 뒤 d / 재접속: tmux attach -t l2comm
> ```

### 8-1. Artifact Registry (Host 프로젝트)

```bash
gcloud artifacts repositories list \
  --project=gcp-prod-edp-hub-vpchost --location=asia-northeast3 \
  --format="table(name.basename(), format)"
```

기대: `ar-l2comm-python`, `ar-l2comm-helm` (둘 다 DOCKER).

AR 이 Host 프로젝트에 있으므로 **저장소 레벨 IAM** 이 핵심입니다.

```bash
gcloud artifacts repositories get-iam-policy ar-l2comm-python \
  --project=gcp-prod-edp-hub-vpchost --location=asia-northeast3 \
  --format="yaml(bindings)"
```

기대:

```text
roles/artifactregistry.writer : sa-l2comm-gke@gcp-prod-edp-edge-509423...
roles/artifactregistry.reader : 541022739403-compute@...   (Autopilot Node SA)
                                620081195575-compute@...   (VM SA)
                                user:cho@sonmap.net
```

### 8-2. 통합 서비스 계정

```bash
gcloud projects get-iam-policy gcp-prod-edp-edge-509423 \
  --flatten="bindings[].members" \
  --filter="bindings.members:sa-l2comm-gke@" \
  --format="value(bindings.role)"
```

기대 (Edge 에 4개): `bigquery.jobUser`, `compute.viewer`,
`logging.logWriter`, `storage.objectViewer`

> `workflows.invoker`, `container.developer`, `artifactregistry.writer` 가
> 여기에 **없어야** 정상입니다. AR 권한은 8-1 의 저장소 레벨에 있습니다.

### 8-3. Job 생성 주체 권한

```bash
gcloud projects get-iam-policy gcp-prod-edp-edge-509423 \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/container.developer" \
  --format="value(bindings.members)"
```

기대: `user:cho@sonmap.net` 과 VM SA 포함.

### 8-4. BigQuery Dataset 권한

```bash
bq show --format=prettyjson pjt-c-admin:dlk_sample \
  | python3 -c "import json,sys; [print(a) for a in json.load(sys.stdin)['access'] if 'l2comm' in str(a)]"
```

기대:

```text
{'role': 'WRITER', 'userByEmail': 'sa-l2comm-gke@gcp-prod-edp-edge-509423.iam.gserviceaccount.com'}
```

> 조직에 따라 `bq add-iam-policy-binding --dataset` 이 allowlist 기능이라
> 거부될 수 있습니다. 그 경우 스크립트가 자동으로 dataset ACL 방식으로
> 전환해 `WRITER` 로 부여합니다. `WRITER` 는 `roles/bigquery.dataEditor`
> 와 동등하므로 둘 중 어느 형태로 보여도 정상입니다.

### 8-5. Workload Identity 바인딩

```bash
gcloud iam service-accounts get-iam-policy \
  sa-l2comm-gke@gcp-prod-edp-edge-509423.iam.gserviceaccount.com \
  --project=gcp-prod-edp-edge-509423 --format="yaml(bindings)"
```

기대: `roles/iam.workloadIdentityUser` 에
`serviceAccount:gcp-prod-edp-edge-509423.svc.id.goog[l2comm-batch/ksa-l2comm-batch]`

### 8-6. GKE 클러스터

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
servicesIpv4Cidr: 34.118.224.0/20      <- GKE managed
masterIpv4CidrBlock: 10.254.5.0/28
enablePrivateEndpoint: true
workloadPool: gcp-prod-edp-edge-509423.svc.id.goog
```

### 8-7. Cloud Build Trigger

```bash
gcloud builds triggers describe trg-l2comm03-python-image \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3 \
  --format="yaml(name, filename, serviceAccount, includedFiles,
                 repositoryEventConfig.push.branch)"
```

기대:

```text
includedFiles: app/**, cloudbuild/**, gcloud/**
serviceAccount: ...sa-l2comm-gke@...
repository: .../repositories/Gcp_Managed_GKE_L2Comm03
```

> **저장소 경로를 반드시 확인하십시오.** L2Comm02 의 트리거
> `trg-l2comm-python-image` 를 재사용하면 L2Comm02 소스로 빌드되어
> 빌드 로그에 `REPO_FULL_NAME: sonmap/Gcp_Managed_GKE_L2Comm02` 가 찍힙니다.
> L2Comm03 은 `trg-l2comm03-python-image` 를 따로 사용하며, 스크립트가
> 기존 트리거의 저장소 불일치를 감지하면 중단합니다.

---

## 9. 이미지 빌드

### 9-1. 수동 빌드 실행

```bash
gcloud builds triggers run trg-l2comm03-python-image \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3 \
  --branch=main
```

### 9-2. 상태 확인

```bash
gcloud builds list \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3 \
  --limit=5 --format="table(id, status, createTime, duration)"
```

기대: 최신 빌드가 `SUCCESS`. `WORKING` 이면 몇 분 대기 후 재확인.

실패 시 로그:

```bash
BUILD_ID=$(gcloud builds list --project=gcp-prod-edp-edge-509423 \
  --region=asia-northeast3 --limit=1 --format="value(id)")

gcloud builds log "${BUILD_ID}" \
  --project=gcp-prod-edp-edge-509423 --region=asia-northeast3
```

### 9-3. 이미지 생성 확인

```bash
gcloud artifacts docker images list \
  asia-northeast3-docker.pkg.dev/gcp-prod-edp-hub-vpchost/ar-l2comm-python \
  --include-tags --format="table(package, tags, createTime)"
```

기대: `python-bq-batch` 에 `v1` 태그.

---

## 10. VM NFS 및 kubectl 준비

### 10-1. /ssw/dlk 심볼릭 링크

```bash
cd ~/Gcp_Managed_GKE_L2Comm03
bash ssw/dlk/install-vm.sh
```

L2Comm02 PoC 를 같은 VM 에서 했다면 `/ssw/dlk` 가 이미 02 체크아웃을
가리키고 있어 아래 오류가 납니다.

```text
ERROR: /ssw/dlk already exists and is not the expected symlink.
```

먼저 무엇을 가리키는지 확인합니다.

```bash
ls -ld /ssw/dlk
readlink -f /ssw/dlk
```

다른 체크아웃을 가리키는 **심볼릭 링크**이면 03 으로 다시 겁니다.

```bash
REPOINT=true bash ssw/dlk/install-vm.sh
```

심볼릭 링크가 아니라 **실제 디렉터리**이면 백업 후 재실행합니다.

```bash
sudo mv /ssw/dlk /ssw/dlk.bak
bash ssw/dlk/install-vm.sh
```

### 확인

```bash
ls -l /ssw/dlk
readlink -f /ssw/dlk
```

기대: `~/Gcp_Managed_GKE_L2Comm03/ssw/dlk` 를 가리키는 심볼릭 링크.

### 10-2. NFS 서버 구성

```bash
sudo bash /ssw/dlk/setup-nfs-server.sh
```

### 확인

```bash
findmnt /srv/l2comm-nfs
exportfs -v
ss -lntp | grep 2049
ls /srv/l2comm-nfs/python
```

기대: bind mount 존재, export 목록 출력, 2049 LISTEN,
`bq_sample.py` 와 `requirements.txt` 가 보임.

VM 내부 IP 를 기록해 둡니다.

```bash
hostname -I | awk '{print $1}'
```

### 10-3. 방화벽 구성 — **Owner 계정**

Host 프로젝트에 두 종류의 규칙이 필요합니다.

| 규칙 | 경로 | 없으면 |
|---|---|---|
| `fw-allow-l2comm-nfs` | GKE Node/Pod → VM NFS (tcp:2049) | PVC 가 `Pending` 에서 멈춤 |
| `fw-l2comm-master-to-node` | Control Plane(`10.254.5.0/28`) → Node (tcp:10250 등) | `kubectl logs` / `exec` 가 `No agent available` |

두 번째 규칙은 Shared VPC 환경에서 GKE 가 Host 프로젝트에 자동 생성하지
못하는 경우가 있어 명시적으로 만듭니다. Job 실행 자체에는 영향이 없지만
로그와 exec 가 막힙니다.

> **선행 조건**: 노드 네트워크 태그를 조회해야 하므로 클러스터에 노드가
> 한 번이라도 기동된 뒤 실행하십시오. 배치를 한 번 돌리면 노드가 뜹니다.
> 아직이면 §11 을 먼저 수행하고 여기로 돌아오셔도 됩니다.

```bash
cd ~/Gcp_Managed_GKE_L2Comm03

gcloud config set account admin@sonmap.net
./gcloud/11-firewall.sh
gcloud config set account cho@sonmap.net
```

스크립트가 하는 일:

1. 현재 규칙 목록 출력
2. `fw-allow-l2comm-nfs` 생성 (이미 있으면 SKIP)
3. NFS 서버 VM 에 `l2comm-nfs` 태그 부여
   (실행 중인 VM 을 메타데이터로 자동 인식, 이미 있으면 SKIP)
4. 노드 네트워크 태그를 자동 조회해 `fw-l2comm-master-to-node` 생성
5. 결과 출력

다른 VM 이 NFS 서버이면 지정해 실행합니다.

```bash
NFS_VM_NAME=<VM> NFS_VM_ZONE=<ZONE> NFS_VM_PROJECT=<PRJ> \
  ./gcloud/11-firewall.sh
```

### 확인

```bash
gcloud compute firewall-rules list \
  --project=gcp-prod-edp-hub-vpchost \
  --filter="network:vpc-prod-edp-hub" \
  --format="table(name, sourceRanges.list(), allowed[].map().firewall_rule().list(), targetTags.list())" \
  | grep -E "NAME|2049|10.254.5"
```

기대: 2049 규칙과 `10.254.5.0/28` 출발 규칙이 모두 보임.

```bash
export KUBECONFIG=$HOME/.kube/config_new-autopilot
kubectl -n kube-system get pods -l k8s-app=konnectivity-agent
```

기대: `Running`.

> `allowed.ports` 는 Compute API 의 서버측 필터가 지원하지 않습니다.
> (`Invalid list filter expression`) 포트는 위처럼 `grep` 으로 거릅니다.

### 10-4. 클러스터 자격증명

`client_gke` 는 기본적으로 `$HOME/.kube/config_new-autopilot` 를 봅니다.

```bash
KUBECONFIG=$HOME/.kube/config_new-autopilot \
gcloud container clusters get-credentials gke-l2comm-batch-an3 \
  --project=gcp-prod-edp-edge-509423 \
  --region=asia-northeast3 \
  --internal-ip
```

### 확인

```bash
export KUBECONFIG=$HOME/.kube/config_new-autopilot
kubectl cluster-info
kubectl get nodes
```

기대: Control Plane 주소 응답. 타임아웃이면 §13 참고.

### 10-5. Namespace / KSA

```bash
kubectl get ns l2comm-batch
kubectl -n l2comm-batch get serviceaccount ksa-l2comm-batch -o yaml
```

기대: 어노테이션에
`iam.gke.io/gcp-service-account: sa-l2comm-gke@gcp-prod-edp-edge-509423.iam.gserviceaccount.com`

없으면 생성합니다.

```bash
kubectl create namespace l2comm-batch
kubectl -n l2comm-batch create serviceaccount ksa-l2comm-batch
kubectl -n l2comm-batch annotate serviceaccount ksa-l2comm-batch \
  iam.gke.io/gcp-service-account=sa-l2comm-gke@gcp-prod-edp-edge-509423.iam.gserviceaccount.com \
  --overwrite
```

### 10-6. Workload Identity 실제 동작 확인

```bash
kubectl -n l2comm-batch run wi-test --rm -it --restart=Never \
  --image=google/cloud-sdk:slim \
  --overrides='{"spec":{"serviceAccountName":"ksa-l2comm-batch"}}' \
  -- gcloud auth list
```

기대: `sa-l2comm-gke@gcp-prod-edp-edge-509423.iam.gserviceaccount.com` 이 활성 계정.

> Autopilot 이 Node 를 띄우므로 1~3분 걸릴 수 있습니다.

---

## 11. 배치 실행

### 11-0. 두 가지 실행 대상 (중요)

`run-gke.sh` 의 8~10번 파라미터(`WORKING_DIRECTORY` / `PROGRAM_PATH` /
`PROGRAM_PARAM`)가 **Pod 안에서 무엇을 실행할지**를 결정합니다.
두 가지 대상이 있으며 용도가 다릅니다.

| 대상 | 경로 | 소스 위치 | 동작 |
|---|---|---|---|
| **적재 배치** | `/app` + `main.py` | 컨테이너 이미지 내부 | GCP 리전 43건을 BigQuery 에 **적재** |
| NFS 조회 샘플 | `/mnt/l2comm/python` + `bq_sample.py` | VM NFS (Git `mnt/`) | 적재된 테이블을 10건 **조회**만 함 |

- **PoC 검증 기준(`row_count = 43`)을 만드는 것은 적재 배치입니다.**
- NFS 샘플은 "Git 으로 관리하는 스크립트를 NFS 로 Pod 에 전달한다"는
  경로를 검증하기 위한 것이며, 테이블에 행을 추가하지 않습니다.
- 이미지의 `WORKDIR` 는 `/app`, 엔트리포인트 스크립트는 `main.py` 입니다
  (`app/Dockerfile` 참고).

### 11-1. DRY_RUN — 매니페스트만 확인

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
image: ...gcp-prod-edp-hub-vpchost/ar-l2comm-python/python-bq-batch:v1
cpu "4" / memory "16Gi"
mountPath: /mnt/l2comm
```

파라미터 계약 검증 (9개만 주면 usage 출력 후 종료):

```bash
./ssw/dlk/run-gke.sh 20261016 20261016 20261016 180000 0 4 16 /mnt/l2comm/python python
```

기대: Usage 출력, exit 1.

### 11-2. 적재 배치 실행 (PoC 검증 기준)

이미지 내부의 `main.py` 를 실행해 BigQuery 에 43건을 적재합니다.

```bash
DRY_RUN=0 \
DOCKER_IMAGE=asia-northeast3-docker.pkg.dev/gcp-prod-edp-hub-vpchost/ar-l2comm-python/python-bq-batch:v1 \
./ssw/dlk/run-gke.sh \
  20261016 20261016 20261016 180000 \
  0 4 16 \
  /app \
  python main.py
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

> 첫 실행은 Autopilot 이 Node 를 새로 띄우므로 2~5분 걸릴 수 있습니다.

### 11-2b. NFS 경로 검증 (조회 샘플)

Git `mnt/` 의 스크립트가 NFS 를 통해 Pod 에 전달되는지 확인합니다.
**테이블에 행을 추가하지 않습니다.** 11-2 를 먼저 수행해야 조회할 데이터가 있습니다.

```bash
DRY_RUN=0 \
DOCKER_IMAGE=asia-northeast3-docker.pkg.dev/gcp-prod-edp-hub-vpchost/ar-l2comm-python/python-bq-batch:v1 \
./ssw/dlk/run-gke.sh \
  20261016 20261016 20261016 180000 \
  0 4 16 \
  /mnt/l2comm/python \
  python bq_sample.py
```

기대 로그:

```text
[INFO] BigQuery job project : gcp-prod-edp-edge-509423
[INFO] Sample table         : pjt-c-admin.dlk_sample.gcp_region_inventory
[INFO] Limit                : 10
[INFO] rows=10
africa-south1   UP      africa-south1   ...
```

> 로그가 **비어 있으면** NFS 가 올바른 저장소를 export 하고 있는지
> 확인하십시오. `/ssw/dlk` 재지정 후 `setup-nfs-server.sh` 를 다시
> 돌리지 않으면 이전(L2Comm02) `mnt/` 가 계속 export 됩니다.
>
> ```bash
> findmnt /srv/l2comm-nfs
> ls -l /srv/l2comm-nfs/python/
> ```
>
> `findmnt` 의 SOURCE 가 `.../Gcp_Managed_GKE_L2Comm03/mnt` 여야 합니다.

### 11-3. 다른 터미널에서 관찰

```bash
export KUBECONFIG=$HOME/.kube/config_new-autopilot

kubectl -n l2comm-batch get jobs -w
```

```bash
kubectl -n l2comm-batch get pods -w
```

Pod 상세 / 로그:

```bash
POD=$(kubectl -n l2comm-batch get pods \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')

kubectl -n l2comm-batch describe pod "${POD}"
kubectl -n l2comm-batch logs "${POD}" -f
```

### 11-4. Job 보존 실행 (디버깅용)

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

## 12. 결과 확인

### 12-1. BigQuery 적재 건수

```bash
bq query --project_id=pjt-c-admin --use_legacy_sql=false \
  'SELECT COUNT(*) AS row_count
   FROM `pjt-c-admin.dlk_sample.gcp_region_inventory`'
```

기대: `row_count = 43`

### 12-2. 샘플 데이터

```bash
bq query --project_id=pjt-c-admin --use_legacy_sql=false \
  'SELECT * FROM `pjt-c-admin.dlk_sample.gcp_region_inventory` LIMIT 10'
```

### 12-3. 전체 상태 일괄 점검

```bash
cd ~/Gcp_Managed_GKE_L2Comm03
./gcloud/99-verify.sh
```

### 12-4. 정기 실행 등록 (선택)

Cloud Scheduler 를 쓰지 않으므로 VM `crontab` 으로 처리합니다.

```bash
crontab -e
```

```cron
0 9 * * * cd $HOME/Gcp_Managed_GKE_L2Comm03 && \
  KUBECONFIG=$HOME/.kube/config_new-autopilot DRY_RUN=0 \
  ./ssw/dlk/run-gke.sh $(date +\%Y\%m\%d) $(date +\%Y\%m\%d) \
  $(date +\%Y\%m\%d) $(date +\%H\%M\%S) 0 4 16 \
  /mnt/l2comm/python python bq_sample.py \
  >> /var/log/l2comm-batch.log 2>&1
```

확인:

```bash
crontab -l
```

---

## 13. 오류 대응

| 증상 | 원인 | 조치 |
|---|---|---|
| 스크립트가 계정 오류로 중단 | 계정 분리 규칙 | `00-bootstrap.sh` / `10-network.sh` 는 `admin@sonmap.net`, `20`·`30`·`90` 은 `cho@sonmap.net`. `gcloud config set account <계정>` |
| `gke-gcloud-auth-plugin` not found | 플러그인 미설치 | §3 재실행 후 `export USE_GKE_GCLOUD_AUTH_PLUGIN=True` |
| `kubectl` 타임아웃 | VPC 외부이거나 라우팅 문제 | VM 이 `vpc-prod-edp-hub` 내부인지 확인, `--internal-ip` 로 재인증 (10-4) |
| `PERMISSION_DENIED` (subnet 생성) | Owner 아닌 계정으로 10-network 실행 | `gcloud config set account admin@sonmap.net` 후 재실행 |
| GKE 생성 시 subnet 접근 거부 | 배포 주체의 Subnet networkUser 누락 | §5-6 확인. 없으면 Owner 로 `10-network.sh` 재실행 |
| Shared VPC 연결 실패 | Owner 의 조직 수준 `compute.xpnAdmin` 없음 | §4-6 으로 확인. 조직 관리자가 Owner 계정에 부여해야 함 |
| Cluster 생성 실패 | GKE Service Agent 권한 | `10-network.sh` 재실행 후 `container.hostServiceAgentUser` 확인 |
| Build `denied: ...uploadArtifacts` | Build SA 의 AR writer 누락 | AR 이 Host 프로젝트이므로 **저장소 레벨** writer 확인 (8-1) |
| Pod `ImagePullBackOff` | 크로스 프로젝트 AR 권한 | 저장소 레벨 reader 확인 (8-1), `AUTOPILOT_NODE_SA` 값 대조 |
| Pod 에서 BigQuery 403 | Workload Identity 미연결 | KSA 어노테이션(10-5)과 `workloadIdentityUser`(8-5) 확인, 10-6 으로 실동작 검증 |
| PVC `Pending` | NFS 미기동 / IP 불일치 / 방화벽 | §10-2 확인, Owner 로 `./gcloud/11-firewall.sh` 실행. `--nfs-server <VM_IP>` 로 명시 지정 |
| Job 생성 403 | 실행 주체 권한 | `container.developer` 확인 (8-3) |
| `cloudbuild.connections.list denied` | 배포 주체에 `cloudbuild.connectionAdmin` 없음 | §6-2 로 점검 후 Owner 로 `00-bootstrap.sh` 재실행 |
| 저장소 추가 시 `NOT_FOUND` / `PERMISSION_DENIED` | GitHub App 이 L2Comm03 에 접근 불가 | §7-2 에서 GitHub App Repository access 에 L2Comm03 추가 |
| `BigQuery error ... This feature requires allowlisting` | `bq add-iam-policy-binding --dataset` 미지원 조직 | 자동으로 dataset ACL 방식으로 폴백됨. 8-4 로 `WRITER` 부여 확인 |
| 빌드 로그에 `REPO_FULL_NAME: ...L2Comm02` | L2Comm02 트리거를 재사용함 | `trg-l2comm03-python-image` 를 사용. 최신 소스로 `git pull` 후 `30-platform.sh` 재실행 |
| `triggers create github: unrecognized arguments: <트리거명>` | 트리거 이름을 위치 인자로 전달 | 최신 소스로 `git pull`. `--name=` 플래그를 사용하도록 수정됨 |
| `kubectl logs` 가 `No agent available` | Private cluster 의 konnectivity 미연결 (마스터→노드 방화벽 누락) | Job 자체는 정상. `client_gke` 가 Cloud Logging 으로 자동 폴백함. 근본 해결은 Owner 로 `./gcloud/11-firewall.sh` 실행 (§10-3) |
| NFS 샘플 실행 로그가 비어 있음 | 이전 저장소(L2Comm02)의 `mnt/` 가 export 중 | `findmnt /srv/l2comm-nfs` 확인 후 `sudo bash /ssw/dlk/setup-nfs-server.sh` 재실행 |
| 적재했는데 `row_count` 가 늘지 않음 | 조회 샘플(`bq_sample.py`)만 실행함 | 적재는 `/app` + `main.py` (11-2). NFS 샘플은 조회 전용 |
| `Invalid value for field 'filter'` (firewall-rules list) | `allowed.ports` 는 서버측 필터 미지원 | 네트워크로만 필터하고 포트는 `grep 2049` 로 거름 (10-3) |
| `git pull` 이 local changes 로 중단 | `chmod +x` 로 인한 권한 비트 변경 | `git checkout -- <파일>` 후 재시도. 반복되면 `git config core.fileMode false` |
| `/ssw/dlk already exists and is not the expected symlink` | L2Comm02 체크아웃을 가리키는 링크가 남음 | `readlink -f /ssw/dlk` 확인 후 `REPOINT=true bash ssw/dlk/install-vm.sh` (실제 디렉터리면 백업 후 재실행) |
| `create-auto: unrecognized arguments: --workload-pool` | Autopilot 은 해당 플래그 미지원 | 최신 소스로 `git pull`. Autopilot 은 WI 가 기본 활성화이며 pool 은 자동 설정됨 |
| `enable_master_authorized_networks should be enabled if private endpoint is enabled` | 플래그 조합 누락 | 최신 소스로 `git pull`. `--enable-master-authorized-networks` 가 함께 지정됨 |
| 생성 중 Cloud NAT 안내 메시지 | Private nodes 안내(오류 아님) | AR 은 Private Google Access 로 접근하므로 무시 가능. 공인 인터넷 egress 가 필요하면 Cloud NAT 구성 |
| `ALREADY_EXISTS` 로 중단 | 멱등 처리 밖의 자원 | 메시지의 자원명을 확인하고 기존 것을 그대로 사용 |

### 디버깅 명령

```bash
export KUBECONFIG=$HOME/.kube/config_new-autopilot

# 이벤트
kubectl -n l2comm-batch get events --sort-by=.lastTimestamp | tail -20

# PVC / PV 상태
kubectl -n l2comm-batch get pvc,pv

# VM 에서 NFS 자체 점검
showmount -e $(hostname -I | awk '{print $1}')

# 현재 계정 / 프로젝트
gcloud config list
```

---

## 14. 정리

```bash
export KUBECONFIG=$HOME/.kube/config_new-autopilot
kubectl -n l2comm-batch delete jobs --all
```

전체 자원 삭제 (각 단계 확인 프롬프트):

```bash
cd ~/Gcp_Managed_GKE_L2Comm03
./gcloud/90-teardown.sh
```

> 서비스 계정과 IAM 바인딩은 자동 삭제되지 않습니다.
> 스크립트가 마지막에 출력하는 수동 정리 명령을 참고하십시오.
