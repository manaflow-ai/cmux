#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/opt/app/rootfs}"

for d in proc sys dev dev/pts; do
  mkdir -p "$ROOT/$d"
done

mountpoint -q "$ROOT/proc"    || mount -t proc proc "$ROOT/proc"
mountpoint -q "$ROOT/sys"     || mount -t sysfs sysfs "$ROOT/sys"
mountpoint -q "$ROOT/dev"     || mount --bind /dev "$ROOT/dev"
mountpoint -q "$ROOT/dev/pts" || mount --bind /dev/pts "$ROOT/dev/pts"

if [ ! -e "$ROOT/etc/resolv.conf" ] && [ -e /etc/resolv.conf ]; then
  mkdir -p "$ROOT/etc"
  cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
fi

ENV_FILE="${ENV_FILE:-/opt/app/app.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

USERSPEC="${USERSPEC:-}"
WORKDIR="${WORKDIR:-/}"

cd_target="$ROOT$WORKDIR"
if [ ! -d "$cd_target" ]; then
  mkdir -p "$cd_target"
fi

if [ -n "$USERSPEC" ]; then
  exec chroot --userspec="$USERSPEC" "$ROOT" sh -c "cd ${WORKDIR@Q} && exec \"$@\""
else
  exec chroot "$ROOT" sh -c "cd ${WORKDIR@Q} && exec \"$@\""
fi
