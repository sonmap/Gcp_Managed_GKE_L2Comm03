#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/ssw/dlk"

chmod +x "$SCRIPT_DIR/run-gke.sh" "$SCRIPT_DIR/client_gke" "$SCRIPT_DIR/setup-nfs-server.sh"

sudo mkdir -p /ssw

if [[ -e "$TARGET" || -L "$TARGET" ]]; then
  CURRENT="$(readlink -f "$TARGET" 2>/dev/null || true)"

  if [[ -L "$TARGET" && "$CURRENT" == "$SCRIPT_DIR" ]]; then
    echo "[OK] $TARGET already points to $SCRIPT_DIR"
    exit 0
  fi

  # 심볼릭 링크이고 다른 체크아웃(예: L2Comm02)을 가리키는 경우에만
  # REPOINT=true 로 다시 걸 수 있습니다. 실제 디렉터리는 건드리지 않습니다.
  if [[ -L "$TARGET" && "${REPOINT:-false}" == "true" ]]; then
    echo "[INFO] repointing $TARGET"
    echo "       before: $CURRENT"
    echo "       after : $SCRIPT_DIR"
    sudo rm -f "$TARGET"
    sudo ln -s "$SCRIPT_DIR" "$TARGET"
    echo "[OK] $TARGET -> $SCRIPT_DIR"
    echo
    echo "Next:"
    echo "  sudo bash /ssw/dlk/setup-nfs-server.sh"
    exit 0
  fi

  echo "ERROR: $TARGET already exists and is not the expected symlink."
  echo "       current: ${CURRENT:-<unresolved>}"
  echo "       wanted : $SCRIPT_DIR"
  echo
  if [[ -L "$TARGET" ]]; then
    echo "It is a symlink to another checkout. To repoint it at this repository:"
    echo "  REPOINT=true bash ssw/dlk/install-vm.sh"
  else
    echo "It is a real directory, not a symlink."
    echo "Move or back it up first; this script will not overwrite it."
    echo "  sudo mv $TARGET ${TARGET}.bak"
    echo "  bash ssw/dlk/install-vm.sh"
  fi
  exit 1
fi

sudo ln -s "$SCRIPT_DIR" "$TARGET"

echo "[OK] $TARGET -> $SCRIPT_DIR"
echo
echo "Next:"
echo "  sudo bash /ssw/dlk/setup-nfs-server.sh"
