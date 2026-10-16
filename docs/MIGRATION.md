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

Network / IAM / Runtime 설계값은 L2Comm02와 **완전히 동일**합니다.

## 2. L2Comm 대비 변경점 (Network 설계, L2Comm02에서 계승)

| 항목 | 기존 L2Comm | L2Comm03 최종 |
|---|---|---|
| Node Primary | `10.254.0.0/28` | `10.252.1.0/24` |
| Pod Secondary | `10.254.2.0/23` | `100.64.128.0/19` |
| Service Secondary | `10.254.4.0/24` | 별도 Secondary 미사용 |
| Service CIDR | Subnet Secondary | GKE Managed / 별도 CIDR 미설정 |
| Control Plane | `10.254.5.0/28` | `10.254.5.0/28` 유지 |
| Image Build | Git 변경 시 Trigger | 동일, Batch 실행과 분리 |
| Runtime | Scheduler -> Workflow -> GKE Job | 동일 |

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
9. ./gcloud/40-scheduler.sh
10. ./gcloud/99-verify.sh (GKE Job / BigQuery 결과 확인)
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
