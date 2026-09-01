#!/usr/bin/env bash
# Reap only the app and cmuxd processes belonging to one target-scale run.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/console-home.sh
source "$script_dir/console-home.sh"

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <perf-tag>" >&2
  exit 2
fi

tag="$1"
case "$tag" in
  ''|*[!A-Za-z0-9._-]*)
    echo "invalid perf tag" >&2
    exit 2
    ;;
esac

home="${HOME:?HOME must be set}"
debug_socket="/tmp/cmux-debug-${tag}.sock"
app_pattern="cmux DEV ${tag}.app/Contents/MacOS/cmux DEV"
cmuxd_pattern="cmuxd-dev-${tag}.sock"
cmuxd_sockets=("$home/Library/Application Support/cmux/cmuxd-dev-${tag}.sock")
console_user="$(stat -f %Su /dev/console 2>/dev/null || true)"
if [ -n "$console_user" ] && [ "$console_user" != "root" ] && [ "$console_user" != "loginwindow" ]; then
  console_home="$(cmux_console_home "$console_user")"
  if [ -n "$console_home" ] && [ "$console_home" != "$home" ]; then
    cmuxd_sockets+=("$console_home/Library/Application Support/cmux/cmuxd-dev-${tag}.sock")
  fi
fi

collect_pattern_pids() {
  pgrep -f "$1" 2>/dev/null || true
}

collect_socket_pids() {
  local socket="$1"
  [ -e "$socket" ] || return 0
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -t "$socket" 2>/dev/null || true
}

pids="$({
  collect_pattern_pids "$app_pattern"
  collect_pattern_pids "$cmuxd_pattern"
  for cmuxd_socket in "${cmuxd_sockets[@]}"; do
    collect_socket_pids "$cmuxd_socket"
  done
} | awk -v self="$$" -v parent="$PPID" '$1 ~ /^[0-9]+$/ && $1 != self && $1 != parent && !seen[$1]++ { print $1 }')"

signal_pids() {
  local signal_name="$1" pid
  [ -n "$pids" ] || return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill "-$signal_name" "$pid" 2>/dev/null || true
  done <<EOF
$pids
EOF
}

signal_pids TERM
pending="$pids"
deadline=$(( $(date +%s) + 5 ))
while [ -n "$pending" ] && [ "$(date +%s)" -lt "$deadline" ]; do
  alive=""
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
      if [ -n "$alive" ]; then
        alive="$(printf '%s\n%s' "$alive" "$pid")"
      else
        alive="$pid"
      fi
    fi
  done <<EOF
$pending
EOF
  pending="$alive"
  [ -n "$pending" ] || break
  sleep 0.1
done

if [ -n "$pending" ]; then
  pids="$pending"
  signal_pids KILL
fi

rm -f "$debug_socket"
for cmuxd_socket in "${cmuxd_sockets[@]}"; do
  rm -f "$cmuxd_socket"
done
