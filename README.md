# Gcp_Managed_GKE_L2Comm03

`Gcp_Managed_GKE_L2Comm02`의 **gcloud CLI 전환판**입니다.
Network / IAM / Runtime 설계는 L2Comm02와 동일하며, 프로비저닝 수단만
Terraform + Infrastructure Manager 에서 **gcloud 스크립트**로 바뀌었습니다.

| | L2Comm02 | L2Comm03 (이 저장소) |
|---|---|---|
| 프로비저닝 | Terraform `terraform/00·10·30` | gcloud `gcloud/*.sh` |
| 30 단계 | Infrastructure Manager Deployment | gcloud 직접 실행 |
| 상태 관리 | GCS tfstate | 없음 (`99-verify.sh` 점검) |
| 삭제 | `terraform destroy` | `90-teardown.sh` |
| 배포 주체 | `admin@sonmap.net` → `sa-l2comm-tf-admin` 가장 | `cho@sonmap.net` 직접 실행 (IAM·네트워크는 Owner) |
| 런타임 SA | cloudbuild / workflow / runtime 3개 | `sa-l2comm-gke` 1개로 통합 |

---

## 1. TO-BE 핵심 구조

```
[Source / Image Build - 소스 변경 시만]
GitHub main push
  -> Cloud Build Trigger
  -> Cloud Build
  -> Artifact Registry
  -> python-bq-batch:v1 저장

[Batch Runtime - 매 실행 시]
run-gke.sh (파라미터 10개)
  -> client_gke
  -> GKE Autopilot Job
  -> 기존 Artifact Registry Image Pull
  -> Python Batch
  -> BigQuery
  -> Job Complete / Pod 종료
```

> **Workflows / Cloud Scheduler를 타지 않습니다.** VM에서 `run-gke.sh`가 `client_gke`를
> 통해 GKE API로 Job을 직접 생성하고 완료까지 대기합니다.
>
> 이미지 Build와 Batch 실행은 분리되어 있습니다. `run-gke.sh`를 여러 번 실행해도
> 소스 변경이 없다면 Docker Image를 다시 Build하지 않습니다.

### 배치 실행 예시

```bash
DRY_RUN=0 \
DOCKER_IMAGE=asia-northeast3-docker.pkg.dev/gcp-prod-edp-hub-vpchost/ar-l2comm-python/python-bq-batch:v1 \
./ssw/dlk/run-gke.sh \
  20261016 20261016 20261016 180000 \
  0 4 16 \
  /app \
  python main.py
```

8~10번 파라미터가 Pod 안에서 실행할 대상을 결정합니다.

| 대상 | 8번 | 9·10번 | 동작 |
|---|---|---|---|
| 적재 배치 | `/app` | `python main.py` | 이미지 내부 스크립트로 BigQuery 43건 적재 |
| NFS 조회 샘플 | `/mnt/l2comm/python` | `python bq_sample.py` | Git `mnt/` 스크립트를 NFS 로 전달해 10건 조회 |

| # | 파라미터 | 예시 |
|---|---|---|
| 1 | `FROM_BASE_YMD` | `20261016` |
| 2 | `TO_BASE_YMD` | `20261016` |
| 3 | `CURR_YMD` | `20261016` |
| 4 | `CURR_TIME` | `180000` |
| 5 | `VM_GPU` | `0` |
| 6 | `VM_CPU` | `4` |
| 7 | `VM_MEM` (GiB) | `16` |
| 8 | `WORKING_DIRECTORY` | `/app` |
| 9 | `PROGRAM_PATH` | `python` |
| 10 | `PROGRAM_PARAM` | `main.py` |

정기 실행이 필요하면 VM의 `crontab`에서 `run-gke.sh`를 호출합니다.

---

## 2. Project / Resource

| 구분 | Project / Resource | 역할 |
|---|---|---|
| Shared VPC Host | `gcp-prod-edp-hub-vpchost` | VPC/Subnet 소유 + **Artifact Registry** |
| Edge / Runtime | `gcp-prod-edp-edge-509423` | GKE, Cloud Build |
| Data | `pjt-c-admin` | BigQuery 데이터 저장 |
| VPC | `vpc-prod-edp-hub` | 기존 172 서비스망과 신규 GKE 대역 공존 |
| GKE | `gke-l2comm-batch-an3` | Private GKE Autopilot |
| Artifact Registry | `gcp-prod-edp-hub-vpchost` / `ar-l2comm-python` | Python batch image (Host 프로젝트) |
| Batch 실행 | `ssw/dlk/run-gke.sh` + `client_gke` | Kubernetes Job 생성/대기 (Workflows 미사용) |
| 통합 SA | `sa-l2comm-gke` | Build / Runtime 전 구간 |
| Owner | `admin@sonmap.net` | **IAM 부여 + 네트워크 관리** (`00-bootstrap.sh`, `10-network.sh`) |
| 배포 주체 | `cho@sonmap.net` | 20 단계 이후 자원 생성/운영 |

---

## 3. Network 설계 - 최종 CIDR

| 구분 | Range | CIDR | 용도 |
|---|---|---|---|
| Node Primary | Primary | `10.252.1.0/24` | GKE Node IP |
| Pod Secondary | `pods-prod-edp-l2comm-an3` | `100.64.128.0/19` | Pod IP |
| Service | GKE Managed | 미설정 | ClusterIP Service |
| Control Plane | Master CIDR | `10.254.5.0/28` | Private Control Plane |

Service Secondary Range는 Subnet에 생성하지 않습니다. Autopilot 1.27+ 는
GKE-managed `34.118.224.0/20` 을 사용합니다.

### Routing 원칙

- 동일 VPC의 Subnet/Secondary Range 사이에는 별도 Static Route를 추가하지 않습니다.
- Firewall / Hierarchical Firewall / Network Policy는 별도 허용 여부를 확인합니다.
- 온프레미스 통신 시 `100.64.128.0/19`의 BGP 광고 및 Return Route를 확인합니다.
- `10.252.1.0/24`, `100.64.128.0/19`, `10.254.5.0/28`은 기존 사내/VPN/CGNAT 대역과 중복 여부를 구축 전에 확인합니다.

---

## 4. 실행 방법

```bash
git clone https://github.com/sonmap/Gcp_Managed_GKE_L2Comm03.git
cd Gcp_Managed_GKE_L2Comm03
chmod +x gcloud/*.sh

# 프로젝트/CIDR/SA 값 확인 후 수정
vi gcloud/00-env.sh
```

### 1단계 — Owner 계정 (IAM 부여 + 네트워크 관리)

```bash
gcloud auth login admin@sonmap.net
gcloud config set account admin@sonmap.net

./gcloud/00-bootstrap.sh          # API 활성화 / IAM 부여
./gcloud/10-network.sh            # Shared VPC / Subnet / Subnet IAM
./gcloud/11-firewall.sh           # NFS 2049 / Control Plane→Node 방화벽
```

> `11-firewall.sh` 는 노드 네트워크 태그를 조회하므로 클러스터 생성
> (`30-platform.sh`) 이후에 실행합니다. 2단계를 먼저 끝내고 Owner 로
> 돌아와 실행하십시오.

### 2단계 — 배포 주체 계정

```bash
gcloud config set account cho@sonmap.net

./gcloud/05-check-permissions.sh  # 권한 사전 점검 (FAIL 시 1단계 재실행)
./gcloud/20-source-connection.sh  # Cloud Build GitHub Repository 연결
./gcloud/30-platform.sh           # AR / SA / Trigger / GKE Autopilot / Namespace / KSA
./gcloud/99-verify.sh             # 전체 상태 점검
```

> Owner 영역은 IAM 부여와 Shared VPC·Subnet 관리입니다. 배포 주체에게는
> Host 프로젝트 전체 네트워크 권한을 주지 않고, `10-network.sh` 가 해당
> Subnet 한정으로 `compute.networkUser` 만 부여합니다.
> 각 스크립트는 시작 시 실행 계정을 검증하며, 계정이 다르면 전환 방법을
> 안내하고 중단합니다. 의도적으로 다른 계정을 쓰려면 `SKIP_ACCOUNT_CHECK=1`.

배치 실행은 프로비저닝이 아니라 VPC 내부 VM에서 수행합니다 (§1 참고).

`30-platform.sh` 의 GKE Autopilot 생성에 15~25분이 소요됩니다.
각 스크립트는 멱등이므로 중간 실패 후 재실행해도 안전합니다.

Ubuntu VM에서 `git clone`부터 배치 실행까지 복사해 쓰는 전체 절차는
[`docs/RUNBOOK.md`](docs/RUNBOOK.md),
Terraform ↔ gcloud 매핑표는 [`gcloud/README.md`](gcloud/README.md) 를 참고하십시오.

---

## 5. 디렉터리 구성

```
gcloud/                     # 프로비저닝 스크립트 (L2Comm02의 terraform/ 대체)
├─ 00-env.sh                # 공통 변수 + 멱등 헬퍼
├─ 00-bootstrap.sh
├─ 10-network.sh
├─ 11-firewall.sh            # Host 방화벽 (NFS / Control Plane→Node)
├─ 05-check-permissions.sh   # 배포 주체 권한 사전 점검
├─ 20-source-connection.sh
├─ 30-platform.sh
├─ 90-teardown.sh           # terraform destroy 대체
├─ 99-verify.sh             # terraform output / plan 대체
└─ README.md

app/                        # Python batch + Dockerfile
cloudbuild/cloudbuild.yaml  # Image build 정의
helm/l2comm-batch/          # Helm chart
docs/                       # DESIGN.md / MIGRATION.md
k8s/debug-pod.yaml          # 배치와 동일 환경의 디버그 Pod (접속용)
ssw/dlk/                    # VM run-gke.sh / client_gke / debug-gke.sh / NFS PoC
mnt/                        # NFS PV 마운트용 Python 샘플
```

---

## 6. GitHub / Cloud Build

Cloud Build Trigger는 `main` branch의 아래 경로 변경 시 Image를 자동 Build합니다.

```
app/**
cloudbuild/**
gcloud/**
```

Build 성공 시 아래 Image가 생성됩니다.

```
asia-northeast3-docker.pkg.dev/gcp-prod-edp-hub-vpchost/ar-l2comm-python/python-bq-batch:v1
```

---

## 7. 사전 확인 필수

1. `10.252.1.0/24`이 기존 서버망/Shared VPC와 중복되지 않는지 확인
2. `100.64.128.0/19`이 사내 CGNAT/VPN/보안장비에서 사용 중인지 확인
3. On-Prem 연동 시 `100.64.128.0/19` Return Route 확인
4. `10.254.5.0/28` Control Plane CIDR 중복 여부 확인
5. 기존 `github-l2comm` Connection에서 이 Repository 연결
6. Artifact Registry가 Host 프로젝트에 있으므로, Node SA / Build SA의 **저장소 레벨** IAM 확인
7. 실행 주체에 Host 프로젝트 `compute.networkAdmin` 및 Shared VPC 연결용 `compute.xpnAdmin` 보유 여부 확인

---

## 8. 검증 기준

```
Cloud Build SUCCESS
-> Artifact Registry Image 생성
-> run-gke.sh
-> client_gke
-> GKE Job Complete 1/1
-> BigQuery pjt-c-admin.dlk_sample.gcp_region_inventory
-> 43 rows 적재
```

Private endpoint 클러스터이므로 `kubectl` 확인은 VPC 내부 VM에서 수행합니다.

```bash
gcloud container clusters get-credentials gke-l2comm-batch-an3 \
  --region=asia-northeast3 --project=gcp-prod-edp-edge-509423 --internal-ip
kubectl get jobs -n l2comm-batch
```

---

## 9. VM `run-gke.sh` / NFS PV PoC

```
ssw/dlk/
├─ run-gke.sh
├─ client_gke
├─ install-vm.sh
├─ setup-nfs-server.sh
└─ README.md

mnt/
├─ README.md
└─ python/
   ├─ bq_sample.py
   └─ requirements.txt
```

VM에서 Git pull 후:

```bash
cd ~/Gcp_Managed_GKE_L2Comm03
git pull

bash ssw/dlk/install-vm.sh
sudo bash /ssw/dlk/setup-nfs-server.sh
```

상세 실행 방법은 `ssw/dlk/README.md`를 참고합니다.
