#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/opt/app/rootfs}"
for mount in dev/pts dev sys proc; do
  if mountpoint -q "$ROOT/$mount"; then
    umount -l "$ROOT/$mount" || true
  fi
done
