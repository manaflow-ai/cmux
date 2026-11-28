#!/usr/bin/env bash
# Run xcodebuild and preserve the failure evidence that a self-hosted runner can
# otherwise hide when the compiler is terminated under resource pressure.
set -u -o pipefail

if [[ "${1:-}" != "--" || "$#" -lt 2 ]]; then
  echo "usage: $0 -- <xcodebuild command and arguments...>" >&2
  exit 2
fi
shift

started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
started_epoch="$(date '+%s')"
echo "xcodebuild diagnostic wrapper start: $started_at"
printf 'xcodebuild command:'
printf ' %q' "$@"
printf '\n'

# Blacksmith terminates a job whose command stream is idle while a compiler is
# still working. xcodebuild can legitimately spend several minutes in one
# Swift-driver operation without emitting a line, so keep the runner informed
# with a bounded heartbeat. The interval is overrideable for deterministic
# tests, but never disabled in the nightly workflow.
heartbeat_seconds="${CMUX_XCODEBUILD_HEARTBEAT_SECONDS:-30}"
if ! [[ "$heartbeat_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || ! awk -v interval="$heartbeat_seconds" 'BEGIN { exit !((interval + 0) > 0) }'; then
  echo "CMUX_XCODEBUILD_HEARTBEAT_SECONDS must be a positive number" >&2
  exit 2
fi

set +e
collect_process_tree() {
  local pid="$1"
  local descendant
  printf '%s\n' "$pid"
  for descendant in $(pgrep -P "$pid" 2>/dev/null); do
    collect_process_tree "$descendant"
  done
}

terminate_child() {
  local process_tree
  local pid
  process_tree="$(collect_process_tree "$child_pid")"
  for pid in $process_tree; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  local deadline=$(( $(date '+%s') + 5 ))
  while :; do
    local alive=0
    for pid in $process_tree; do
      if kill -0 "$pid" 2>/dev/null; then
        alive=1
        break
      fi
    done
    [[ "$alive" -eq 0 ]] && break
    if [[ "$(date '+%s')" -ge "$deadline" ]]; then
      for pid in $process_tree; do
        kill -KILL "$pid" 2>/dev/null || true
      done
      break
    fi
    sleep 0.1
  done
}

"$@" &
child_pid=$!
interrupted_signal=0
handle_signal() {
  interrupted_signal="$1"
  terminate_child
}
trap 'handle_signal 2' INT
trap 'handle_signal 15' TERM
(
  heartbeat_sleep_pid=""
  heartbeat_cleanup() {
    if [[ -n "$heartbeat_sleep_pid" ]]; then
      kill "$heartbeat_sleep_pid" 2>/dev/null || true
    fi
    exit 143
  }
  trap heartbeat_cleanup INT TERM
  while kill -0 "$child_pid" 2>/dev/null; do
    sleep "$heartbeat_seconds" &
    heartbeat_sleep_pid=$!
    wait "$heartbeat_sleep_pid"
    heartbeat_sleep_pid=""
    kill -0 "$child_pid" 2>/dev/null || break
    now_epoch="$(date '+%s')"
    elapsed=$((now_epoch - started_epoch))
    echo "xcodebuild heartbeat: pid=$child_pid elapsed=${elapsed}s"
  done
) &
heartbeat_pid=$!
wait "$child_pid"
status=$?
if [[ "$interrupted_signal" -ne 0 ]]; then
  status=$((128 + interrupted_signal))
fi
kill "$heartbeat_pid" 2>/dev/null || true
wait "$heartbeat_pid" 2>/dev/null || true
trap - INT TERM
set -e

finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "xcodebuild diagnostic wrapper finish: $finished_at"
echo "xcodebuild exit status: $status"

if [[ "$status" -eq 0 ]]; then
  exit 0
fi

if [[ "$status" -ge 128 ]]; then
  signal_number=$((status - 128))
  echo "xcodebuild termination: signal=$signal_number (shell status=$status)"
else
  echo "xcodebuild termination: exited normally (status=$status)"
fi
echo "::error::xcodebuild failed with status=$status; resource diagnostics follow"

print_diagnostic() {
  local label="$1"
  shift
  echo "--- $label ---"
  if "$@"; then
    return 0
  fi
  echo "$label unavailable (command failed or is not supported on this runner)"
}

print_diagnostic "host" uname -a
print_diagnostic "memory and CPU" bash -c '
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.memsize 2>/dev/null || true
    sysctl -n hw.ncpu 2>/dev/null || true
    sysctl vm.swapusage 2>/dev/null || true
  fi
  if command -v vm_stat >/dev/null 2>&1; then
    vm_stat 2>/dev/null || true
  fi
  if command -v memory_pressure >/dev/null 2>&1; then
    memory_pressure -Q 2>/dev/null || true
  fi
'
print_diagnostic "disk" df -h .
print_diagnostic "top processes by resident memory" bash -c '
  ps -axo pid,ppid,%cpu,%mem,rss,vsz,state,command 2>/dev/null \
    | sort -nrk5 \
    | head -25
'
print_diagnostic "compiler processes" bash -c '
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -fal "xcodebuild|swiftc|clang|sourcekit" || true
  else
    ps -axo pid,ppid,%cpu,%mem,rss,vsz,state,command 2>/dev/null \
      | grep -E "xcodebuild|swiftc|clang|sourcekit" \
      | grep -v grep \
      || true
  fi
'

exit "$status"
