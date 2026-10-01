#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 start|stop <state-file>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
ACTION="$1"
STATE_FILE="$2"
ANCHOR="com.cmux.iroh-release-gate"

require_tools() {
  [[ "$(uname -s)" == "Darwin" ]] || { echo "error: latency impairment requires macOS" >&2; exit 1; }
  command -v dnctl >/dev/null || { echo "error: dnctl is unavailable" >&2; exit 1; }
  command -v pfctl >/dev/null || { echo "error: pfctl is unavailable" >&2; exit 1; }
  sudo -n true >/dev/null 2>&1 || {
    echo "error: passwordless sudo is required for the reversible latency profile" >&2
    exit 1
  }
}

case "$ACTION" in
  start)
    [[ ! -e "$STATE_FILE" ]] || { echo "error: latency state already exists: $STATE_FILE" >&2; exit 1; }
    require_tools
    delay_ms="${CMUX_IROH_LATENCY_DELAY_MS:-150}"
    [[ "$delay_ms" =~ ^[1-9][0-9]*$ ]] || { echo "error: CMUX_IROH_LATENCY_DELAY_MS must be positive" >&2; exit 2; }
    pipe_id=$((300 + ($$ % 600)))
    pf_was_enabled=0
    if sudo -n pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
      pf_was_enabled=1
    fi
    mkdir -p "$(dirname "$STATE_FILE")"
    if ! sudo -n dnctl pipe "$pipe_id" config delay "${delay_ms}ms"; then
      echo "error: could not configure dummynet pipe" >&2
      exit 1
    fi
    if ! printf 'dummynet out proto udp from any to any pipe %s\n' "$pipe_id" | sudo -n pfctl -a "$ANCHOR" -f - >/dev/null; then
      sudo -n dnctl pipe "$pipe_id" delete >/dev/null 2>&1 || true
      echo "error: could not install pf latency rule" >&2
      exit 1
    fi
    if [[ "$pf_was_enabled" -eq 0 ]]; then
      sudo -n pfctl -E >/dev/null
    fi
    {
      printf 'pipe_id=%s\n' "$pipe_id"
      printf 'delay_ms=%s\n' "$delay_ms"
      printf 'pf_was_enabled=%s\n' "$pf_was_enabled"
      printf 'anchor=%s\n' "$ANCHOR"
      printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    echo "latency impairment active: ${delay_ms}ms UDP delay, state=$STATE_FILE"
    ;;
  stop)
    [[ -f "$STATE_FILE" ]] || exit 0
    require_tools
    # State is written by this script and contains only numeric values and the
    # fixed anchor name. Read it without evaluating shell code.
    pipe_id="$(awk -F= '$1 == "pipe_id" { print $2 }' "$STATE_FILE")"
    pf_was_enabled="$(awk -F= '$1 == "pf_was_enabled" { print $2 }' "$STATE_FILE")"
    [[ "$pipe_id" =~ ^[0-9]+$ && "$pf_was_enabled" =~ ^[01]$ ]] || {
      echo "error: invalid latency state: $STATE_FILE" >&2
      exit 1
    }
    sudo -n pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
    sudo -n dnctl pipe "$pipe_id" delete >/dev/null 2>&1 || true
    if [[ "$pf_was_enabled" -eq 0 ]]; then
      sudo -n pfctl -d >/dev/null 2>&1 || true
    fi
    printf 'stopped_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$STATE_FILE"
    echo "latency impairment removed: state=$STATE_FILE"
    ;;
  *) usage ;;
esac
