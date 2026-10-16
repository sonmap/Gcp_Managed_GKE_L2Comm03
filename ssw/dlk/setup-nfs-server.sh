#!/usr/bin/env bash
set -euo pipefail

# PoC helper: export this repository's mnt/ directory from the current VM via NFSv4.
# Production recommendation: use managed Filestore rather than the VM root disk.

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GIT_MNT="$REPO_ROOT/mnt"
NFS_ROOT="${NFS_ROOT:-/srv/l2comm-nfs}"

if [[ ! -d "$GIT_MNT" ]]; then
  echo "ERROR: Git mnt directory not found: $GIT_MNT"
  exit 1
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-kernel-server

mkdir -p "$NFS_ROOT"

# Always repair the bind mount. An older script could resolve /ssw/dlk as a
# logical symlink and accidentally bind /mnt instead of <repo>/mnt.
if mountpoint -q "$NFS_ROOT"; then
  umount "$NFS_ROOT"
fi
mount --bind "$GIT_MNT" "$NFS_ROOT"

# Keep only the correct persistent bind entry for this NFS root.
touch /etc/fstab
sed -i "\|[[:space:]]$NFS_ROOT[[:space:]][[:space:]]*none[[:space:]][[:space:]]*bind|d" /etc/fstab
FSTAB_LINE="$GIT_MNT $NFS_ROOT none bind 0 0"
echo "$FSTAB_LINE" >> /etc/fstab

# Read-only NFSv4 root export. Remove stale/broken entries first.
touch /etc/exports
sed -i -e '/^\$EXPORT_LINE[[:space:]]*$/d' \
       -e "\|^[[:space:]]*$NFS_ROOT[[:space:]]|d" \
       /etc/exports

EXPORT_LINE="$NFS_ROOT *(ro,sync,no_subtree_check,root_squash,fsid=0)"
echo "$EXPORT_LINE" >> /etc/exports

exportfs -ra
systemctl enable --now nfs-kernel-server

SERVER_IP="$(hostname -I | awk '{print $1}')"

echo
echo "============================================================"
echo "NFSv4 PoC server ready"
echo "============================================================"
echo "Git source : $GIT_MNT"
echo "NFS bind   : $NFS_ROOT"
echo "Server IP  : $SERVER_IP"
echo "Client path: /"
echo "Mode       : read-only"
echo "Port       : TCP 2049"
echo "============================================================"
echo
echo "Verify:"
echo "  findmnt $NFS_ROOT"
echo "  exportfs -v"
echo "  ss -lntp | grep 2049"
echo
echo "GKE Node Primary CIDR 10.252.1.0/24 must be allowed to TCP/2049 on this VM."
