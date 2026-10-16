# L2Comm02 -> L2Comm03 Migration Notes

`Gcp_Managed_GKE_L2Comm03`는 `L2Comm02`의 Network 설계를 그대로 유지하면서,
**프로비저닝 수단을 Terraform / Infrastructure Manager 에서 gcloud CLI 로 전환**한 버전입니다.

## 1. L2Comm02 대비 변경점 (프로비저닝 방식)

| 항목 | L2Comm02 | L2Comm03 |
|---|---|---|
| IaC 도구 | Terraform (`terraform/00·10·30`) | gcloud CLI (`gcloud/*.sh`) |
| 30 단계 실행 | Infrastructure Manager Deployment | gcloud 직접 실행 |
| 상태 관리 | GCS tfstate 버킷 + state | 없음 (`99-verify.sh` 로 상태 점검) |
| 삭제 | `terraform destroy` | `90-teardown.sh` (대화형 확인) |
| 멱등성 | state 기반 | `describe \|\| create` + `ok_if_exists()` |
| 불필요해진 자원 | — | `sa-l2comm-inframgr`, `roles/config.agent`, `roles/config.admin`, `config.googleapis.com`, tfstate 버킷 |
| Build Trigger 감시 경로 | `terraform/30-infra-manager/**` | `gcloud/**` |
| 배포 주체 | `admin@sonmap.net` → `sa-l2comm-tf-admin` 가장 | `chomap@sonmap.net` 직접 실행 |
| 런타임 SA | `sa-l2comm-cloudbuild` / `sa-l2comm-workflow` / `sa-l2comm-runtime` | `sa-l2comm-gke` 1개로 통합 |
| 배치 실행 경로 | Scheduler → Workflows → GKE Job | `run-gke.sh` → `client_gke` → GKE Job |
| 정기 실행 | Cloud Scheduler | VM `crontab` |

Network 설계값(CIDR / Subnet / Control Plane)은 L2Comm02와 **완전히 동일**하며,
IAM 주체 구성만 아래와 같이 단순화했습니다.

## 1-1. 서비스 계정 단순화

```text
L2Comm02                          L2Comm03
─────────────────────────         ─────────────────────────
sa-l2comm-tf-admin        ──┐
                            └──>  chomap@sonmap.net (직접 실행, 동일 Role 집합)

sa-l2comm-cloudbuild      ──┐
sa-l2comm-workflow        ──┼──>  sa-l2comm-gke (Role 합집합)
sa-l2comm-runtime         ──┘
```

영향 범위:

| 대상 | 변경 |
|---|---|
| `cloudbuild/cloudbuild.yaml` | `serviceAccount:` → `sa-l2comm-gke` |
| Cloud Build Trigger | `--service-account` → `sa-l2comm-gke` |
| Workload Identity | `ksa-l2comm-batch` → `sa-l2comm-gke` |
| `helm/l2comm-batch/values.yaml` | `gcpServiceAccount` → `sa-l2comm-gke` |
| `ssw/dlk/client_gke` | `RUNTIME_GSA` → `sa-l2comm-gke` |

> 통합으로 Build 주체와 Runtime 주체의 권한 분리가 약해집니다.
> 운영 전환 시 분리가 필요하면 `00-env.sh` 에서 용도별 SA 로 되돌릴 수 있습니다.

### 기존 환경에서 이관하는 경우

L2Comm02 자원이 이미 떠 있다면 통합 SA 생성 후 기존 3개 SA 를 정리합니다.

```bash
./gcloud/30-platform.sh   # sa-l2comm-gke 생성 + Trigger 재배포 + Namespace/KSA 갱신

# 신규 Job/Build 가 정상 동작하는 것을 확인한 뒤 삭제
for S in sa-l2comm-runtime sa-l2comm-workflow sa-l2comm-cloudbuild sa-l2comm-tf-admin; do
  gcloud iam service-accounts delete \
    "${S}@gcp-prod-edp-edge-509423.iam.gserviceaccount.com" \
    --project=gcp-prod-edp-edge-509423
done
```

> SA 삭제 전에 `remove-iam-policy-binding` 으로 부여된 Role 을 먼저 회수하십시오.
> 삭제된 SA 의 바인딩은 `deleted:serviceAccount:...` 형태로 정책에 잔류합니다.

### Workflows / Scheduler 정리

L2Comm02 에서 넘어오는 경우 더 이상 쓰이지 않는 자원을 삭제합니다.

```bash
gcloud scheduler jobs delete sch-l2comm-gke-job \
  --project=gcp-prod-edp-edge-509423 --location=asia-northeast3

gcloud workflows delete wf-l2comm-gke-job \
  --project=gcp-prod-edp-edge-509423 --location=asia-northeast3

# API 도 함께 비활성화할 수 있습니다 (다른 용도로 쓰지 않는 경우에만)
gcloud services disable workflows.googleapis.com workflowexecutions.googleapis.com \
  cloudscheduler.googleapis.com --project=gcp-prod-edp-edge-509423
```

정기 실행이 필요했다면 VM 의 `crontab` 으로 대체합니다.

```cron
0 9 * * * DRY_RUN=0 /ssw/dlk/run-gke.sh $(date +\%Y\%m\%d) $(date +\%Y\%m\%d) \
  $(date +\%Y\%m\%d) $(date +\%H\%M\%S) 0 4 16 /mnt/l2comm/python python bq_sample.py \
  >> /var/log/l2comm-batch.log 2>&1
```

## 2. L2Comm 대비 변경점 (Network 설계, L2Comm02에서 계승)

| 항목 | 기존 L2Comm | L2Comm03 최종 |
|---|---|---|
| Node Primary | `10.254.0.0/28` | `10.252.1.0/24` |
| Pod Secondary | `10.254.2.0/23` | `100.64.128.0/19` |
| Service Secondary | `10.254.4.0/24` | 별도 Secondary 미사용 |
| Service CIDR | Subnet Secondary | GKE Managed / 별도 CIDR 미설정 |
| Control Plane | `10.254.5.0/28` | `10.254.5.0/28` 유지 |
| Image Build | Git 변경 시 Trigger | 동일, Batch 실행과 분리 |
| Runtime | Scheduler -> Workflow -> GKE Job | run-gke.sh -> client_gke -> GKE Job |

## 3. 현재 상태

기존 GKE Autopilot과 기존 Infra Manager Deployment는 삭제된 상태입니다.
기존 L2Comm 전용 Subnet을 수동 정리한 뒤 신규 Network를 생성합니다.

권장 순서:

```text
1. 기존 GKE Cluster 삭제 확인
2. 기존 L2Comm 전용 Subnet 삭제 확인
3. 신규 CIDR 중복 확인
4. ./gcloud/00-bootstrap.sh
5. ./gcloud/10-network.sh
   - Node Primary 10.252.1.0/24
   - Pod Secondary 100.64.128.0/19
   - Service Secondary 없음
6. Subnet 최종 상태 확인
7. ./gcloud/20-source-connection.sh
8. ./gcloud/30-platform.sh
   - GKE Autopilot 신규 생성
9. ./gcloud/99-verify.sh
10. VPC 내부 VM 에서 ssw/dlk/run-gke.sh 실행 (GKE Job / BigQuery 결과 확인)
```

## 4. Terraform 에서 이관하는 경우

L2Comm02를 이미 `terraform apply` 로 구축한 상태라면, 동일 자원을 gcloud 로 다시
만들 필요는 없습니다. 스크립트가 모두 `describe || create` 이므로 기존 자원은
건너뛰고 누락분만 생성합니다. 다만 **tfstate 는 더 이상 갱신되지 않으므로**
Terraform 과 gcloud 를 동시에 쓰지 않도록 운영 주체를 하나로 정리하십시오.

## CIDR 사전 확인

```text
10.252.1.0/24
- 기존 서버망/Shared VPC/Subnet/Peering과 중복 여부

100.64.128.0/19
- 사내 CGNAT/VPN/보안장비 사용 여부
- Interconnect를 통한 On-Prem Return Route 가능 여부

10.254.5.0/28
- Private Control Plane용 10.x /28
- VPC/Peering/On-Prem Route와 중복 여부
```

## 동일 VPC 내부 통신

동일 Shared VPC 내에서 정상 등록된 Subnet/Secondary Range 사이에는 별도 Static Route를 추가하지 않습니다.

```text
Pod 100.64.128.x
  -> GCP VPC system route
  -> GCP 내부 172.x / 10.x 서비스
```

단, 대상 서비스의 Firewall/HFP/Network Policy가 Pod Source 대역을 허용해야 합니다.

## On-Prem 통신

```text
Pod 100.64.128.0/19
  -> Cloud Router / Interconnect
  -> On-Prem

On-Prem
  -> Return Route 100.64.128.0/19
  -> GCP
```

GCP -> On-Prem Forward Route만 존재하고 Return Route가 없으면 통신이 실패합니다.
