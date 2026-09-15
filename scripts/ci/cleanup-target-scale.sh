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
app_marker="cmux DEV ${tag}.app/Contents/MacOS/cmux DEV"
cmuxd_marker="cmuxd-dev-${tag}.sock"
cmuxd_sockets=("$home/Library/Application Support/cmux/cmuxd-dev-${tag}.sock")
console_user="$(stat -f %Su /dev/console 2>/dev/null || true)"
if [ -n "$console_user" ] && [ "$console_user" != "root" ] && [ "$console_user" != "loginwindow" ]; then
  console_home="$(cmux_console_home "$console_user")"
  if [ -n "$console_home" ] && [ "$console_home" != "$home" ]; then
    cmuxd_sockets+=("$console_home/Library/Application Support/cmux/cmuxd-dev-${tag}.sock")
  fi
fi

cleanup_failed=0
runner_user="$(id -un 2>/dev/null || true)"
term_grace_seconds="${CMUX_CLEANUP_TERM_GRACE_SECONDS:-5}"
case "$term_grace_seconds" in
  ''|*[!0-9]*)
    echo "invalid CMUX_CLEANUP_TERM_GRACE_SECONDS" >&2
    exit 2
    ;;
esac

collect_process_pids() {
  local pid command
  # Use shell-glob matching on the already validated tag instead of a process
  # name regular expression: a dotted tag remains a literal identity.
  ps -axo pid=,command= 2>/dev/null | while read -r pid command; do
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    case "$command" in
      *"$app_marker"*|*"$cmuxd_marker"*) printf '%s\n' "$pid" ;;
    esac
  done
}

collect_socket_pids() {
  local socket="$1"
  [ -e "$socket" ] || return 0
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -t "$socket" 2>/dev/null || true
}

collect_tagged_pids() {
  {
    collect_process_pids
    for cmuxd_socket in "${cmuxd_sockets[@]}"; do
      collect_socket_pids "$cmuxd_socket"
    done
  } | awk -v self="$$" -v parent="$PPID" '$1 ~ /^[0-9]+$/ && $1 != self && $1 != parent && !seen[$1]++ { print $1 }'
}

intersect_pids() {
  local left="$1" right="$2" pid
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if printf '%s\n' "$right" | awk -v wanted="$pid" '$1 == wanted { found = 1 } END { exit found ? 0 : 1 }'; then
      printf '%s\n' "$pid"
    fi
  done <<EOF
$left
EOF
}

pid_is_currently_tagged() {
  local wanted="$1" current
  current="$(collect_tagged_pids)"
  printf '%s\n' "$current" | awk -v wanted="$wanted" '$1 == wanted { found = 1 } END { exit found ? 0 : 1 }'
}

pids="$(collect_tagged_pids)"

process_owner() {
  local pid="$1" owner
  owner="$(ps -o user= -p "$pid" 2>/dev/null | awk 'NF { print $1; exit }')"
  case "$owner" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
    *) printf '%s\n' "$owner" ;;
  esac
}

signal_one() {
  local signal_name="$1" pid="$2" owner=""
  if kill "-$signal_name" "$pid" 2>/dev/null; then
    return 0
  fi

  # The benchmark can be launched in the Aqua console user's bootstrap while
  # Actions runs as another account.  Retry as the recorded process owner,
  # then as root; never silently turn EPERM into a successful cleanup.
  owner="$(process_owner "$pid")"
  if [ -n "$owner" ] && [ "$owner" != "$runner_user" ] \
    && command -v sudo >/dev/null 2>&1 \
    && sudo -n -u "$owner" /bin/kill "-$signal_name" "$pid" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 \
    && sudo -n /bin/kill "-$signal_name" "$pid" 2>/dev/null; then
    return 0
  fi

  # A process can exit between collection and signaling.  Re-query its tagged
  # identity before treating a failed signal as a harmless race; kill -0 alone
  # cannot distinguish an exited process from an EPERM result.
  if ! pid_is_currently_tagged "$pid"; then
    return 0
  fi
  echo "unable to signal tagged PID $pid with SIG$signal_name" >&2
  return 1
}

signal_pids() {
  local signal_name="$1" pid list
  if [ "$#" -ge 2 ]; then
    list="$2"
  else
    list="$pids"
  fi
  [ -n "$list" ] || return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if ! signal_one "$signal_name" "$pid"; then
      cleanup_failed=1
    fi
  done <<EOF
$list
EOF
}

signal_pids TERM
pending="$pids"
if [ -n "$pending" ] && [ "$term_grace_seconds" -gt 0 ]; then
  # wait-for-pids uses macOS kqueue NOTE_EXIT rather than a fixed shell delay.
  # Keep only identities that still belong to this run after the event wait.
  if waited_pids="$(CMUX_WAIT_PIDS="$pending" "$script_dir/wait-for-pids.py" --timeout "$term_grace_seconds")"; then
    pending="$(intersect_pids "$pending" "$waited_pids")"
  else
    echo "process-exit wait helper failed; retaining tagged PIDs for revalidation" >&2
  fi
fi

if [ -n "$pending" ]; then
  # Revalidate immediately before KILL to avoid signaling a reused PID.
  current_tagged_pids="$(collect_tagged_pids)"
  pending="$(intersect_pids "$pending" "$current_tagged_pids")"
  signal_pids KILL "$pending"
fi

remove_path() {
  local path="$1" owner=""
  [ -e "$path" ] || return 0
  if rm -f "$path" 2>/dev/null && [ ! -e "$path" ]; then
    return 0
  fi

  owner="$(stat -f %Su "$path" 2>/dev/null | awk 'NF { print $1; exit }')"
  case "$owner" in
    ''|*[!A-Za-z0-9._-]*) owner="" ;;
  esac
  if [ -n "$owner" ] && [ "$owner" != "$runner_user" ] \
    && command -v sudo >/dev/null 2>&1 \
    && sudo -n -u "$owner" /bin/rm -f "$path" 2>/dev/null \
    && [ ! -e "$path" ]; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 \
    && sudo -n /bin/rm -f "$path" 2>/dev/null \
    && [ ! -e "$path" ]; then
    return 0
  fi
  [ ! -e "$path" ] && return 0
  echo "unable to remove tagged cleanup path: $path" >&2
  return 1
}

if ! remove_path "$debug_socket"; then
  cleanup_failed=1
fi
for cmuxd_socket in "${cmuxd_sockets[@]}"; do
  if ! remove_path "$cmuxd_socket"; then
    cleanup_failed=1
  fi
done

exit "$cleanup_failed"
