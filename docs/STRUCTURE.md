# 저장소 구조 및 실행 흐름

`Gcp_Managed_GKE_L2Comm03` 의 전체 폴더·파일과, 각 파일이 **어디서 실행되는지**,
**어떤 순서로 쓰이는지** 를 정리한 문서입니다.

---

## 1. 전체 구조 한눈에 보기

```
Gcp_Managed_GKE_L2Comm03/
│
├── gcloud/                  [구축]  관리 VM 또는 작업 PC 에서 실행
│   ├── 00-env.sh                    공통 변수 + 멱등 헬퍼 (모든 스크립트가 source)
│   ├── 00-bootstrap.sh         (1)  API 활성화 / IAM 부여          ← Owner
│   ├── 10-network.sh           (2)  Shared VPC / Subnet / Subnet IAM ← Owner
│   ├── 11-firewall.sh          (6)  NFS 2049 / ControlPlane→Node   ← Owner
│   ├── 05-check-permissions.sh (3)  배포 주체 권한 사전 점검        ← 배포 주체
│   ├── 20-source-connection.sh (4)  Cloud Build 저장소 연결        ← 배포 주체
│   ├── 30-platform.sh          (5)  AR / SA / Trigger / GKE / KSA  ← 배포 주체
│   ├── 99-verify.sh            (*)  전체 상태 점검                 ← 배포 주체
│   ├── 90-teardown.sh          (*)  역순 삭제                      ← 배포 주체
│   └── README.md                    Terraform ↔ gcloud 매핑표
│
├── app/                     [빌드]  Cloud Build 가 이미지로 패키징
│   ├── Dockerfile                   WORKDIR /app, CMD python main.py
│   ├── main.py                      ★ 적재 배치 (리전 43건 → BigQuery)
│   └── requirements.txt
│
├── cloudbuild/              [빌드]  Cloud Build 가 읽는 빌드 정의
│   └── cloudbuild.yaml              docker build → AR push (Host 프로젝트)
│
├── ssw/dlk/                 [실행]  VPC 내부 VM 에서 실행
│   ├── install-vm.sh           (7)  /ssw/dlk 심볼릭 링크 생성
│   ├── setup-nfs-server.sh     (8)  mnt/ → /srv/l2comm-nfs → NFSv4 export
│   ├── run-gke.sh              (9)  ★ 진입점. 파라미터 10개
│   ├── client_gke                   run-gke.sh 가 호출. PV/PVC/Job 생성·대기
│   ├── debug-gke.sh            (*)  디버그 Pod 생성 + 접속
│   └── README.md
│
├── mnt/                     [실행]  VM NFS 로 Pod 에 읽기 전용 공유
│   ├── python/bq_sample.py          조회 샘플 (Pod 의 /mnt/l2comm/python)
│   ├── python/requirements.txt
│   └── README.md
│
├── k8s/                     [실행]  kubectl 로 적용
│   └── debug-pod.yaml               배치와 동일 환경의 대기 Pod
│
├── helm/l2comm-batch/       [참고]  Helm 배포 대안 (현재 미사용)
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/serviceaccount.yaml
│
├── docs/                    [문서]
│   ├── RUNBOOK.md                   ★ 단계별 실행 절차
│   ├── DESIGN.md                    TO-BE 설계
│   ├── MIGRATION.md                 L2Comm02 → 03 전환 내역
│   └── STRUCTURE.md                 (이 문서)
│
└── README.md                        개요 / 빠른 시작
```

`(숫자)` = 실행 순서, `(*)` = 필요할 때, `★` = 핵심 진입점

---

## 2. 실행 위치별 분류

같은 저장소 안에 있지만 **실행 주체와 위치가 다릅니다.**

```
┌──────────────────────────────────────────────────────────┐
│ A. 관리 VM / 작업 PC  (gcloud CLI)                        │
│    gcloud/*.sh                                           │
│    → GCP API 호출로 인프라를 만든다                        │
├──────────────────────────────────────────────────────────┤
│ B. Cloud Build  (GCP 내부, 자동)                          │
│    cloudbuild/cloudbuild.yaml + app/*                    │
│    → 이미지를 만들어 Artifact Registry 에 올린다            │
├──────────────────────────────────────────────────────────┤
│ C. VPC 내부 VM  (infra-son01)                            │
│    ssw/dlk/*  +  mnt/*  +  k8s/*                         │
│    → kubectl 로 GKE 에 Job 을 만들고, NFS 를 제공한다       │
├──────────────────────────────────────────────────────────┤
│ D. GKE Pod  (컨테이너 안)                                 │
│    /app/main.py          ← 이미지에 포함                   │
│    /mnt/l2comm/python/*  ← NFS 마운트 (mnt/ 가 그대로 보임) │
└──────────────────────────────────────────────────────────┘
```

---

## 3. 구축 단계 흐름 (A)

```
[Owner: admin@sonmap.net]
  │
  ├─(1) gcloud/00-bootstrap.sh ──┐ API 활성화 (Edge / Host)
  │        source 00-env.sh      │ 배포 주체에 Role 부여
  │                              │ (Edge 9 / Host 2 / Data 1)
  │                              ▼
  └─(2) gcloud/10-network.sh ────┐ Shared VPC 서비스 프로젝트 연결
           source 00-env.sh      │ Subnet 10.252.1.0/24
                                 │   + Pod 2차 100.64.128.0/19
                                 │ Subnet IAM (networkUser)
                                 ▼
[배포 주체: cho@sonmap.net]      ─ gcloud config set account
  │
  ├─(3) gcloud/05-check-permissions.sh   권한 사전 점검 (FAIL 시 1단계로)
  │
  ├─(4) gcloud/20-source-connection.sh   github-l2comm 연결에
  │                                       L2Comm03 저장소 추가
  │
  └─(5) gcloud/30-platform.sh ───┐ Artifact Registry (Host 프로젝트)
                                 │ sa-l2comm-gke 생성 + IAM
                                 │ Cloud Build Trigger
                                 │ GKE Autopilot Cluster
                                 │ Namespace / KSA
                                 ▼
[Owner]  ─ 클러스터 생성 후 다시 Owner 로
  │
  └─(6) gcloud/11-firewall.sh        NFS 2049 허용
                                      ControlPlane(10.254.5.0/28) → Node
```

> `00-env.sh` 는 실행되지 않고 **모든 스크립트가 `source`** 합니다.
> 프로젝트 ID / CIDR / SA 이름을 한 곳에서 바꾸면 전체에 반영됩니다.

---

## 4. 이미지 빌드 흐름 (B)

```
개발자: git push (main)
   │
   ▼
Cloud Build Trigger  trg-l2comm03-python-image
   │  감시 경로: app/** , cloudbuild/** , gcloud/**
   ▼
cloudbuild/cloudbuild.yaml
   │  steps: docker build  (dir: app)
   │  serviceAccount: sa-l2comm-gke
   ▼
app/Dockerfile
   │  FROM python:3.12-slim
   │  WORKDIR /app
   │  COPY requirements.txt → pip install
   │  COPY main.py
   │  CMD ["python", "main.py"]
   ▼
Artifact Registry  (gcp-prod-edp-hub-vpchost)
   asia-northeast3-docker.pkg.dev/.../ar-l2comm-python/python-bq-batch:v1
```

소스가 바뀔 때만 빌드됩니다. 배치를 아무리 돌려도 이미지는 재빌드되지 않습니다.

---

## 5. VM 준비 흐름 (C)

```
git clone → ~/Gcp_Managed_GKE_L2Comm03
   │
   ├─(7) ssw/dlk/install-vm.sh
   │        /ssw/dlk ─symlink→ <repo>/ssw/dlk
   │        (다른 체크아웃을 가리키면 REPOINT=true)
   │
   └─(8) sudo /ssw/dlk/setup-nfs-server.sh
            <repo>/mnt ─bind mount→ /srv/l2comm-nfs
            NFSv4 export (ro, fsid=0, TCP 2049)
```

**`mnt/` 가 곧 Pod 의 `/mnt/l2comm`** 입니다.
Git 으로 `mnt/python/*.py` 를 고치고 `git pull` 하면 재빌드 없이 Pod 에 반영됩니다.

---

## 6. 배치 실행 흐름 (C → D)

```
VM:  ssw/dlk/run-gke.sh  $1..$10
        │  $1~$4  FROM/TO_BASE_YMD, CURR_YMD, CURR_TIME
        │  $5~$7  VM_GPU, VM_CPU, VM_MEM
        │  $8     WORKING_DIRECTORY  ← 실행 대상을 결정
        │  $9~$10 PROGRAM_PATH, PROGRAM_PARAM
        │
        │  SHELL_COMMAND = "cd $8 && $9 $10"
        ▼
     ssw/dlk/client_gke
        │  PV   (NFS_SERVER:/ , ro)
        │  PVC  (l2comm-git-nfs-pvc)
        │  Job  (batch/v1, KSA=ksa-l2comm-batch)
        │  kubectl apply → wait --for=condition=complete
        │  로그: kubectl logs → 실패 시 Cloud Logging 폴백
        │  Job 삭제 (ttl 600s / KEEP_JOB=1 로 보존)
        ▼
GKE Autopilot Job → Pod
        │  image pull ← Artifact Registry (Host 프로젝트)
        │  Workload Identity: KSA → sa-l2comm-gke
        ▼
   ┌────────────────────────┬────────────────────────────┐
   │ $8 = /app              │ $8 = /mnt/l2comm/python    │
   │ 이미지 내부             │ NFS 마운트 (Git mnt/)       │
   │ python main.py         │ python bq_sample.py        │
   │ → 43건 적재 (INSERT)    │ → 10건 조회 (SELECT)        │
   └────────────────────────┴────────────────────────────┘
        ▼
   BigQuery  pjt-c-admin.dlk_sample.gcp_region_inventory
```

**8번 파라미터가 실행 대상을 바꿉니다.** PoC 검증 기준(`row_count = 43`)을
만드는 것은 `/app` + `main.py` 쪽입니다.

---

## 7. 파일별 요약표

| 경로 | 실행 위치 | 역할 | 호출 주체 |
|---|---|---|---|
| `gcloud/00-env.sh` | — | 공통 변수·헬퍼 | 모든 스크립트가 `source` |
| `gcloud/00-bootstrap.sh` | VM/PC | API·IAM | Owner |
| `gcloud/10-network.sh` | VM/PC | VPC·Subnet | Owner |
| `gcloud/11-firewall.sh` | VM/PC | 방화벽 2종 | Owner (클러스터 생성 후) |
| `gcloud/05-check-permissions.sh` | VM/PC | 권한 점검 | 배포 주체 |
| `gcloud/20-source-connection.sh` | VM/PC | 저장소 연결 | 배포 주체 |
| `gcloud/30-platform.sh` | VM/PC | AR·SA·Trigger·GKE | 배포 주체 |
| `gcloud/99-verify.sh` | VM/PC | 상태 점검 | 아무나 (조회 전용) |
| `gcloud/90-teardown.sh` | VM/PC | 역순 삭제 | 배포 주체 |
| `cloudbuild/cloudbuild.yaml` | Cloud Build | 빌드 정의 | Trigger |
| `app/Dockerfile` | Cloud Build | 이미지 정의 | cloudbuild.yaml |
| `app/main.py` | **Pod `/app`** | 적재 배치 | run-gke.sh |
| `ssw/dlk/install-vm.sh` | VM | 심볼릭 링크 | 사람 |
| `ssw/dlk/setup-nfs-server.sh` | VM (sudo) | NFS export | 사람 |
| `ssw/dlk/run-gke.sh` | VM | 진입점 | 사람 / crontab |
| `ssw/dlk/client_gke` | VM | Job 생성·대기 | run-gke.sh |
| `ssw/dlk/debug-gke.sh` | VM | 디버그 Pod | 사람 |
| `mnt/python/bq_sample.py` | **Pod `/mnt/l2comm/python`** | 조회 샘플 | run-gke.sh |
| `k8s/debug-pod.yaml` | VM → GKE | 대기 Pod | debug-gke.sh |
| `helm/l2comm-batch/*` | — | Helm 대안 (미사용) | — |

---

## 8. 변경 시 영향 범위

| 무엇을 바꾸면 | 무엇을 다시 해야 하나 |
|---|---|
| `gcloud/00-env.sh` | 해당 단계 스크립트 재실행 (전부 멱등) |
| `app/main.py`, `app/Dockerfile` | git push → Trigger 자동 빌드 → 다음 배치부터 반영 |
| `mnt/python/*.py` | VM 에서 `git pull` 만 하면 즉시 반영 (재빌드 불필요) |
| `cloudbuild/cloudbuild.yaml` | git push → 자동 빌드 |
| `ssw/dlk/*` | VM 에서 `git pull` (심볼릭 링크라 즉시 반영) |
| `POD_CIDR` 등 Subnet 설계 | **클러스터 삭제 → Subnet 삭제 → 10-network 재실행** |
