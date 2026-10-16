# L2Comm03 TO-BE Design

## Resource Tree

```text
Organization / Existing Environment
|
+-- Shared VPC Host: gcp-prod-edp-hub-vpchost
|   +-- VPC: vpc-prod-edp-hub
|   +-- Existing Service Networks: 172.x / 10.x
|   +-- GKE Node Subnet: 10.252.1.0/24
|       +-- Pod Secondary: 100.64.128.0/19
|
+-- Edge Project: gcp-prod-edp-edge-509423
|   +-- GKE Autopilot: gke-l2comm-batch-an3
|   |   +-- Control Plane: 10.254.5.0/28
|   |   +-- Service: GKE Managed / 별도 CIDR 미설정
|   |   +-- Namespace: l2comm-batch
|   |   +-- KSA: ksa-l2comm-batch
|   +-- Artifact Registry: ar-l2comm-python
|   +-- Cloud Build Trigger: trg-l2comm-python-image
|   +-- Workflow: wf-l2comm-gke-job
|   +-- Scheduler: sch-l2comm-gke-job
|
+-- Data Project: pjt-c-admin
    +-- Dataset: dlk_sample
        +-- Table: gcp_region_inventory
```

## Capacity Planning

AS-IS 기준:

| 항목 | 요구량 |
|---|---:|
| CPU | 약 40 Core |
| Memory | 약 900 GB |

설계 환산 가정: Node `16 Core / 64 GB`

| 기준 | 계산 | 환산 Node |
|---|---|---:|
| CPU | 40 / 16 | 3 |
| Memory | 900 / 64 | 15 |
| Memory + 30% | 1170 / 64 | 19 |
| 설계 기준 | 반올림/운영 여유 | 약 20 |

Autopilot에서는 실제 Node shape/count를 직접 고정하지 않으며 위 수치는 IP/Capacity 사전 설계를 위한 환산값입니다.

## IP Plan

| 구분 | Range | CIDR | 설명 |
|---|---|---|---|
| Existing Service | - | `172.x / 10.x` | 기존 서비스/서버 네트워크 |
| Node Primary | Primary | `10.252.1.0/24` | GKE Node 전용 |
| Pod Secondary | `pods-prod-edp-l2comm-an3` | `100.64.128.0/19` | Pod 전용, RFC1918 고갈 완화 |
| Service | GKE Managed | 미설정 | 별도 Subnet Secondary Range 미사용 |
| Control Plane | Master CIDR | `10.254.5.0/28` | Private Control Plane |

Control Plane은 `10.x.x.x/28` 조건을 만족하는 기존 `10.254.5.0/28`을 유지합니다.

## Routing

### GCP 동일 Shared VPC

```text
Pod 100.64.128.x
  -> GCP VPC system routing
  -> 172.x / 10.x GCP service
```

별도 Static Route는 추가하지 않습니다. Firewall/HFP/Network Policy는 별도 확인합니다.

### On-Prem 연동

```text
Pod 100.64.128.0/19
  -> Cloud Router / Interconnect
  -> On-Prem

On-Prem
  -> Return Route 100.64.128.0/19
  -> GCP
```

## Service Accounts / IAM

| Principal | Scope | Role / 목적 |
|---|---|---|
| `admin@sonmap.net` | Org/Projects | 00/10 관리자 수행 |
| `sa-l2comm-tf-admin` | Edge/Host/Data | 위임 배포 관리자 (gcloud 스크립트 실행 주체) |
| ~~`sa-l2comm-inframgr`~~ | Edge | **L2Comm03에서 미사용.** Infrastructure Manager 제거로 불필요 (`CREATE_INFRAMGR=true` 시에만 생성) |
| `sa-l2comm-cloudbuild` | Edge | AR Writer, Logging Writer, Storage Viewer |
| `sa-l2comm-workflow` | Edge | Container Developer, Workflows Invoker |
| `sa-l2comm-runtime` | Edge/Data | BigQuery Job User, Compute Viewer, Dataset Data Editor |
| `ksa-l2comm-batch` | GKE Namespace | Workload Identity -> runtime GSA |
| `541022739403-compute@developer.gserviceaccount.com` | Edge / AR | defaultNodeServiceAccount + AR Reader |
| Cloud Build P4SA | Edge | Secret Manager Admin for GitHub 2nd-gen connection |

## CI/CD vs Runtime Separation

```text
[Source changed]
GitHub -> Trigger -> Cloud Build -> Artifact Registry

[Every batch execution]
Scheduler -> Workflow -> GKE Job -> Existing Image Pull -> Python -> BigQuery
```

Docker Build는 배치 실행마다 수행하지 않습니다.
