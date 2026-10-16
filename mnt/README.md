# mnt

이 디렉터리는 **VM에서 Git pull로 갱신하고, NFS로 GKE Pod에 읽기 전용 공유**하기 위한 PoC 소스 영역입니다.

Git Repository 경로 예:

```text
~/Gcp_Managed_GKE_L2Comm03/mnt
└─ python/
   ├─ bq_sample.py
   └─ requirements.txt
```

VM에서는 `ssw/dlk/setup-nfs-server.sh`가 이 디렉터리를
`/srv/l2comm-nfs`에 bind mount하고 NFSv4 root로 export합니다.

Pod에서는 다음 경로로 보입니다.

```text
/mnt/l2comm
└─ python/
   └─ bq_sample.py
```

중요:

- Git 디렉터리 자체가 Kubernetes PV가 되는 것은 아닙니다.
- VM이 NFS 서버 역할을 하고, Kubernetes PV가 VM의 NFS export를 참조합니다.
- 현재 구성은 PoC용 read-only 공유입니다.
- 운영 환경에서는 VM root disk 기반 NFS보다 Google Cloud Filestore 사용을 권장합니다.
