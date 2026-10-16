# gcloud 프로비저닝

`Gcp_Managed_GKE_L2Comm02`의 `terraform/00-bootstrap`, `terraform/10-network`,
`terraform/30-infra-manager`를 gcloud CLI로 1:1 전환한 스크립트입니다.
`20-source-connection`, `40-scheduler`는 L2Comm02에서도 gcloud 기반이었고,
여기서는 멱등성(재실행 안전성)만 보완했습니다.

---

## 1. 파일 구성

| 파일 | L2Comm02 대응 | 내용 |
|---|---|---|
| `00-env.sh` | `*/variables.tf`, `*/terraform.tfvars.example` | 공통 변수 + 멱등 헬퍼. 모든 스크립트가 `source` |
| `00-bootstrap.sh` | `terraform/00-bootstrap` | API 활성화 / SA 생성 / 프로젝트 IAM |
| `10-network.sh` | `terraform/10-network` | Shared VPC 연결 / Subnet / Subnet IAM |
| `20-source-connection.sh` | `20-source-connection/README.md` | Cloud Build GitHub Repository 연결 |
| `30-platform.sh` | `terraform/30-infra-manager` | AR / SA / Trigger / GKE Autopilot / Workflow |
| `40-scheduler.sh` | `40-scheduler/README.md` | Cloud Scheduler (create or update) |
| `90-teardown.sh` | `terraform destroy` | 생성 역순 삭제 (대화형 확인) |
| `99-verify.sh` | `terraform output` / `plan` | 생성 자원 상태 일괄 점검 |
| `workflow.yaml.tmpl` | `workflow.yaml.tftpl` | Workflows 정의. `templatefile()` 대신 `sed` 렌더링 |

---

## 2. 실행

```bash
chmod +x gcloud/*.sh
vi gcloud/00-env.sh          # 프로젝트 ID / CIDR / SA 값 확인

./gcloud/00-bootstrap.sh
./gcloud/10-network.sh       # CIDR 중복 확인 프롬프트 있음
./gcloud/20-source-connection.sh
./gcloud/30-platform.sh      # GKE 생성 15~25분
./gcloud/40-scheduler.sh
./gcloud/99-verify.sh
```

### 선택 플래그

| 환경변수 | 기본값 | 설명 |
|---|---|---|
| `CREATE_INFRAMGR` | `false` | Infrastructure Manager를 병행 운영할 때만 `true`. `sa-l2comm-inframgr` 및 `config.*` 권한 생성 |
| `CREATE_TFSTATE_BUCKET` | `false` | Terraform과 병행할 때만 `true`. gcloud 전용 운영에서는 불필요 |

---

## 3. Terraform → gcloud 매핑표

### 00-bootstrap

| Terraform | gcloud |
|---|---|
| `google_project_service` (edge 17 / host 3) | `gcloud services enable <API...> --project=` — 멱등 |
| `google_storage_bucket.tfstate` | `gcloud storage buckets create` + **`buckets update --versioning` (별도 명령)** |
| `google_service_account` | `gcloud iam service-accounts create` |
| `google_project_iam_member` (for_each) | `gcloud projects add-iam-policy-binding` 반복 |
| `google_storage_bucket_iam_member` | `gcloud storage buckets add-iam-policy-binding` |
| `google_service_account_iam_member` | `gcloud iam service-accounts add-iam-policy-binding` |

### 10-network

| Terraform | gcloud |
|---|---|
| `data.google_project` (프로젝트 번호) | `gcloud projects describe --format='value(projectNumber)'` |
| `google_compute_shared_vpc_service_project` | `gcloud compute shared-vpc associated-projects add` |
| `google_compute_subnetwork` + `secondary_ip_range` | `gcloud compute networks subnets create --range --secondary-range NAME=CIDR --enable-private-ip-google-access` |
| `google_compute_subnetwork_iam_member` | `gcloud compute networks subnets add-iam-policy-binding` |
| `google_project_iam_member` (host) | `gcloud projects add-iam-policy-binding` |
| `output` | `gcloud compute networks subnets describe --format=` |

### 30-infra-manager → 30-platform

| Terraform | gcloud |
|---|---|
| `google_artifact_registry_repository` | `gcloud artifacts repositories create --repository-format=docker` |
| `google_service_account` x3 | `gcloud iam service-accounts create` |
| `google_bigquery_dataset_iam_member` | ⚠️ gcloud에 dataset 레벨 IAM 명령이 없음 → `bq add-iam-policy-binding --dataset=true` |
| `google_artifact_registry_repository_iam_member` | `gcloud artifacts repositories add-iam-policy-binding` |
| `google_cloudbuild_trigger` (2nd-gen) | `gcloud builds triggers create github --repository=projects/../connections/../repositories/.. --branch-pattern` |
| `google_container_cluster` (Autopilot) | `gcloud container clusters create-auto` (§4 참고) |
| `google_service_account_iam_member` (WI) | `add-iam-policy-binding --member="serviceAccount:PROJECT.svc.id.goog[ns/ksa]"` |
| `google_workflows_workflow` + `templatefile()` | `sed` 렌더링 + `gcloud workflows deploy --source=` (생성/갱신 겸용이라 멱등) |

---

## 4. GKE Autopilot 플래그 매핑

HCL 블록과 gcloud 플래그가 직관적으로 대응되지 않는 부분입니다.

| HCL | gcloud |
|---|---|
| `enable_autopilot = true` | 서브커맨드 자체가 `create-auto` |
| `ip_allocation_policy.cluster_secondary_range_name` | `--cluster-secondary-range-name` |
| Service secondary range 미지정 | `--services-secondary-range-name`을 **주지 않음** (GKE managed `34.118.224.0/20`) |
| `private_cluster_config` 3개 필드 | `--enable-private-nodes --enable-private-endpoint --master-ipv4-cidr` |
| `master_authorized_networks_config { private_endpoint_enforcement_enabled = false }` | `--no-enable-authorized-networks-on-private-endpoint` |
| `workload_identity_config.workload_pool` | `--workload-pool` |
| `deletion_protection = false` | gcloud에 해당 개념 없음 (삭제 시 `--quiet`) |
| Shared VPC network/subnetwork | 반드시 **full resource path** 로 지정 (`projects/HOST/global/networks/...`) |

---

## 5. 전환 시 주의사항

### 5-1. 멱등성
Terraform은 state로 "이미 있음"을 판별하지만 gcloud는 `ALREADY_EXISTS` 에러로 종료합니다.
스크립트는 `set -Eeuo pipefail` 상태이므로 `ok_if_exists()` / `describe || create` 패턴으로
재실행 안전성을 확보했습니다. 이 처리가 없으면 중간에 멈춥니다.

### 5-2. IAM 바인딩 동작
- `add-iam-policy-binding`은 Terraform의 `*_iam_member`와 동일하게 **additive** 입니다.
- `--condition=None`을 명시하지 않으면 조건부 바인딩이 있을 때 대화형 프롬프트가 떠서
  자동화가 멈춥니다. 전 구간에 포함했습니다.
- 삭제는 자동이 아니므로 teardown 시 `remove-iam-policy-binding`을 직접 실행해야 합니다.

### 5-3. 실행 순서 (terraform `depends_on` 대체)

```
services enable → SA 생성 → IAM 부여 → Shared VPC 연결
  → Subnet 생성 → Subnet IAM → Cluster 생성 → WI 바인딩 → Workflow → Scheduler
```

특히 **Subnet IAM(`compute.networkUser`)이 Cluster 생성보다 먼저**여야 하고,
`container.hostServiceAgentUser`가 없으면 Autopilot 생성이 실패합니다.

### 5-4. `templatefile()` 대체
`workflow.yaml.tftpl`은 Terraform 보간 `${var}`와 Workflows 표현식 `$${expr}`이
섞여 있어 단순 치환으로는 깨집니다. `workflow.yaml.tmpl`은 Terraform 변수만
`@@VAR@@` 플레이스홀더로 바꾸고 `$${...}` → `${...}` 로 복원해 두었으므로
`sed` 치환만으로 그대로 배포됩니다.

### 5-5. 권한 경계
`10-network.sh`는 Host 프로젝트를 변경하므로 실행 주체에 `compute.networkAdmin`,
Shared VPC 연결에는 조직 수준 `compute.xpnAdmin`이 필요합니다.
Edge 프로젝트 권한만으로는 실패합니다.

### 5-6. 상태 관리 상실
`plan` / `destroy` / drift 감지가 없습니다. 대체 수단:

```bash
./gcloud/99-verify.sh    # 생성 자원 상태 일괄 확인
./gcloud/90-teardown.sh  # 생성 역순 삭제 (각 단계 확인)
```

콘솔에서 수동 변경된 값은 자동 감지되지 않으므로, 변경 시 `00-env.sh` 와
실제 자원을 주기적으로 대조하십시오.

---

## 6. L2Comm02 대비 제거된 자원

gcloud 전환으로 아래가 불필요해졌습니다.

- `sa-l2comm-inframgr` 서비스 계정
- `roles/config.agent`, `roles/config.admin`
- `config.googleapis.com` API
- `gcloud infra-manager deployments apply` 단계
- GCS tfstate 버킷 및 `roles/storage.objectAdmin` 바인딩

병행 운영이 필요하면 `CREATE_INFRAMGR=true`, `CREATE_TFSTATE_BUCKET=true` 로 실행합니다.
