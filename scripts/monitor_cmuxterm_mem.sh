#!/usr/bin/env bash
set -euo pipefail

NAME="cmuxterm DEV"
PID=""
LIMIT_GB=20
INTERVAL=2
METRIC="rss"
LOG_FILE="${TMPDIR:-/tmp}/cmuxterm-memwatch.log"
DUMP_DIR="${TMPDIR:-/tmp}/cmuxterm-memwatch-dumps"
ONCE=0
DRY_RUN=0
DUMP_ON_KILL=1

usage() {
  cat <<'EOF'
Monitor cmuxterm DEV memory and kill after a threshold.

Usage:
  scripts/monitor_cmuxterm_mem.sh [options]

Options:
  --name <process name>   Process name (default: "cmuxterm DEV")
  --pid <pid>             Specific PID to monitor
  --limit-gb <gb>         Kill threshold in GB (default: 20)
  --interval <seconds>    Poll interval (default: 2)
  --metric <rss|vsz>      Metric to compare (default: rss)
  --log <path>            Log file path
  --no-dump               Skip vmmap dump on kill
  --dry-run               Never kill, just log
  --once                  Log once and exit
  -h, --help              Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --pid) PID="$2"; shift 2 ;;
    --limit-gb) LIMIT_GB="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --metric) METRIC="$2"; shift 2 ;;
    --log) LOG_FILE="$2"; shift 2 ;;
    --no-dump) DUMP_ON_KILL=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --once) ONCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$METRIC" != "rss" && "$METRIC" != "vsz" ]]; then
  echo "Invalid --metric (use rss or vsz)" >&2
  exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")" "$DUMP_DIR"

log_line() {
  local msg="$1"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")"
  echo "[$ts] $msg" | tee -a "$LOG_FILE"
}

resolve_pid() {
  if [[ -n "$PID" ]]; then
    return 0
  fi
  local pids
  mapfile -t pids < <(pgrep -x "$NAME" || true)
  if [[ "${#pids[@]}" -eq 0 ]]; then
    PID=""
    return 0
  fi
  if [[ "${#pids[@]}" -eq 1 ]]; then
    PID="${pids[0]}"
    return 0
  fi
  local newest_pid=""
  local newest_age=999999
  for pid in "${pids[@]}"; do
    local age
    age="$(ps -o etimes= -p "$pid" | tr -d ' ' || true)"
    if [[ -n "$age" && "$age" -lt "$newest_age" ]]; then
      newest_age="$age"
      newest_pid="$pid"
    fi
  done
  PID="$newest_pid"
  log_line "Multiple pids (${pids[*]}), monitoring newest PID=$PID"
}

gb_from_kb() {
  awk -v kb="$1" 'BEGIN { printf "%.2f", kb/1024/1024 }'
}

check_once() {
  resolve_pid
  if [[ -z "$PID" ]]; then
    log_line "Process not found: $NAME"
    return 0
  fi
  local rss_kb vsz_kb
  rss_kb="$(ps -o rss= -p "$PID" | tr -d ' ' || true)"
  vsz_kb="$(ps -o vsz= -p "$PID" | tr -d ' ' || true)"
  if [[ -z "$rss_kb" || -z "$vsz_kb" ]]; then
    log_line "Unable to read memory for PID=$PID"
    return 0
  fi
  local rss_gb vsz_gb limit_kb
  rss_gb="$(gb_from_kb "$rss_kb")"
  vsz_gb="$(gb_from_kb "$vsz_kb")"
  limit_kb=$((LIMIT_GB * 1024 * 1024))
  log_line "PID=$PID rss=${rss_gb}GB vsz=${vsz_gb}GB limit=${LIMIT_GB}GB metric=$METRIC"

  local metric_kb
  if [[ "$METRIC" == "rss" ]]; then
    metric_kb="$rss_kb"
  else
    metric_kb="$vsz_kb"
  fi
  if [[ "$metric_kb" -lt "$limit_kb" ]]; then
    return 0
  fi

  log_line "Threshold exceeded. PID=$PID ${METRIC}=${metric_kb}KB"
  if [[ "$DUMP_ON_KILL" -eq 1 ]]; then
    local stamp dump_base
    stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
    dump_base="${DUMP_DIR}/cmuxterm-${PID}-${stamp}"
    if command -v vmmap >/dev/null 2>&1; then
      vmmap -summary "$PID" > "${dump_base}-vmmap.txt" 2>&1 || true
      log_line "vmmap summary saved: ${dump_base}-vmmap.txt"
    fi
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_line "Dry run enabled, not killing PID=$PID"
    return 0
  fi
  kill -TERM "$PID" 2>/dev/null || true
  sleep 3
  if kill -0 "$PID" 2>/dev/null; then
    log_line "PID=$PID still alive after TERM, sending KILL"
    kill -KILL "$PID" 2>/dev/null || true
  else
    log_line "PID=$PID exited after TERM"
  fi
}

if [[ "$ONCE" -eq 1 ]]; then
  check_once
  exit 0
fi

log_line "Starting memwatch name=\"$NAME\" limit=${LIMIT_GB}GB interval=${INTERVAL}s metric=$METRIC"
while true; do
  check_once
  sleep "$INTERVAL"
done
