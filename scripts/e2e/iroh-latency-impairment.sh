#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 start|stop <state-file>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
ACTION="$1"
STATE_FILE="$2"
# The stock macOS pf.conf evaluates the com.apple/* subtree. Keeping our
# anchor below that parent makes the rule active without changing pf.conf.
ANCHOR="com.apple/cmux-iroh-release-gate"

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
    if [[ -e "$STATE_FILE" ]]; then
      if [[ -f "$STATE_FILE" ]] && grep -q '^stopped_at=' "$STATE_FILE"; then
        archive="${STATE_FILE}.previous.$(date +%s).$$"
        mv "$STATE_FILE" "$archive"
        echo "archived completed latency state: $archive" >&2
      else
        echo "error: latency state already exists and is not completed: $STATE_FILE" >&2
        exit 1
      fi
    fi
    require_tools
    delay_ms="${CMUX_IROH_LATENCY_DELAY_MS:-150}"
    [[ "$delay_ms" =~ ^[1-9][0-9]*$ ]] || { echo "error: CMUX_IROH_LATENCY_DELAY_MS must be positive" >&2; exit 2; }
    pipe_id=$((300 + ($$ % 600)))
    pf_was_enabled=0
    if sudo -n pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
      pf_was_enabled=1
    fi
    mkdir -p "$(dirname "$STATE_FILE")"
    resources_started=0
    start_succeeded=0
    rollback_start() {
      [[ "$start_succeeded" -eq 0 && "$resources_started" -eq 1 ]] || return 0
      set +e
      sudo -n pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
      sudo -n dnctl pipe "$pipe_id" delete >/dev/null 2>&1
      if [[ "$pf_was_enabled" -eq 0 ]]; then
        sudo -n pfctl -d >/dev/null 2>&1
      fi
    }
    trap rollback_start EXIT
    if ! sudo -n dnctl pipe "$pipe_id" config delay "${delay_ms}ms"; then
      echo "error: could not configure dummynet pipe" >&2
      exit 1
    fi
    resources_started=1
    if ! printf 'dummynet out proto udp from any to any pipe %s\n' "$pipe_id" | sudo -n pfctl -a "$ANCHOR" -f - >/dev/null; then
      echo "error: could not install pf latency rule" >&2
      exit 1
    fi
    if [[ "$pf_was_enabled" -eq 0 ]]; then
      if ! sudo -n pfctl -E >/dev/null; then
        echo "error: could not enable pf for latency rule" >&2
        exit 1
      fi
    fi
    if ! sudo -n pfctl -a "$ANCHOR" -sr 2>/dev/null | grep -Fq "dummynet out proto udp from any to any pipe $pipe_id"; then
      echo "error: active pf ruleset does not contain the latency rule" >&2
      exit 1
    fi
    state_tmp="${STATE_FILE}.tmp.$$"
    {
      printf 'pipe_id=%s\n' "$pipe_id"
      printf 'delay_ms=%s\n' "$delay_ms"
      printf 'pf_was_enabled=%s\n' "$pf_was_enabled"
      printf 'anchor=%s\n' "$ANCHOR"
      printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$state_tmp"
    chmod 600 "$state_tmp"
    if ! mv "$state_tmp" "$STATE_FILE"; then
      rm -f "$state_tmp"
      echo "error: could not commit latency state" >&2
      exit 1
    fi
    start_succeeded=1
    trap - EXIT
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
    stop_status=0
    if ! sudo -n pfctl -a "$ANCHOR" -F all >/dev/null 2>&1; then
      stop_status=1
    fi
    if ! sudo -n dnctl pipe "$pipe_id" delete >/dev/null 2>&1; then
      # Deleting an already-removed pipe is safe, but an unrelated sudo or
      # dummynet failure must fail the gate and remain visible.
      if sudo -n dnctl pipe show 2>/dev/null | grep -Eq "(^|[[:space:]])${pipe_id}([[:space:]]|:)"; then
        stop_status=1
      fi
    fi
    if [[ "$pf_was_enabled" -eq 0 ]]; then
      if ! sudo -n pfctl -d >/dev/null 2>&1; then
        stop_status=1
      fi
    fi
    printf 'stopped_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$STATE_FILE"
    if [[ "$stop_status" -ne 0 ]]; then
      echo "error: latency impairment cleanup failed; state retained at $STATE_FILE" >&2
      exit 1
    fi
    echo "latency impairment removed: state=$STATE_FILE"
    ;;
  *) usage ;;
esac
