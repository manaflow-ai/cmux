#!/usr/bin/env bash
set -euo pipefail

# Run the existing mobile latency analyzer with minimal path setup.
# This script never prints logs. It prints only derived timings, so callers
# can safely paste the result without exposing tokens or terminal contents.

usage() {
  cat <<'EOF'
Usage:
  scripts/mobile-latency-trace/measure.sh --ios-log PATH [--mac-log PATH] [--same-clock] [--json]
  scripts/mobile-latency-trace/measure.sh --simulator-udid UDID --bundle-id BUNDLE [--mac-log PATH] [--same-clock] [--json]

Physical iPhone logs normally use --ios-log. --same-clock is for a simulator
and Mac running on the same host. Without a Mac log, the report still includes
iPhone-local input RTT and rendering metrics, but cannot calculate cross-device
hop timings.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
ANALYZER="$SCRIPT_DIR/analyze.py"
IOS_LOG=""
MAC_LOG=""
SIMULATOR_UDID=""
BUNDLE_ID=""
SAME_CLOCK=0
AS_JSON=0

while (($#)); do
  case "$1" in
    --ios-log) IOS_LOG="${2:?missing value for --ios-log}"; shift 2 ;;
    --mac-log) MAC_LOG="${2:?missing value for --mac-log}"; shift 2 ;;
    --simulator-udid) SIMULATOR_UDID="${2:?missing value for --simulator-udid}"; shift 2 ;;
    --bundle-id) BUNDLE_ID="${2:?missing value for --bundle-id}"; shift 2 ;;
    --same-clock) SAME_CLOCK=1; shift ;;
    --json) AS_JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$SIMULATOR_UDID" ]]; then
  [[ -n "$BUNDLE_ID" ]] || { echo "error: --bundle-id is required with --simulator-udid" >&2; exit 2; }
  DATA_DIR="$(xcrun simctl get_app_container "$SIMULATOR_UDID" "$BUNDLE_ID" data)"
  IOS_LOG="$DATA_DIR/Library/Application Support/cmux-debug.log"
fi

[[ -n "$IOS_LOG" ]] || { echo "error: provide --ios-log or --simulator-udid + --bundle-id" >&2; usage >&2; exit 2; }
[[ -f "$IOS_LOG" ]] || { echo "error: iOS log does not exist: $IOS_LOG" >&2; exit 2; }
if [[ -n "$MAC_LOG" && ! -f "$MAC_LOG" ]]; then
  echo "error: Mac log does not exist: $MAC_LOG" >&2
  exit 2
fi

TEMP_MAC_LOG=""
if [[ -z "$MAC_LOG" ]]; then
  TEMP_MAC_LOG="$(mktemp -t cmux-mobile-latency-empty.XXXXXX)"
  MAC_LOG="$TEMP_MAC_LOG"
  trap 'rm -f "$TEMP_MAC_LOG"' EXIT
fi

ARGS=("--mac-log" "$MAC_LOG" "--ios-log" "$IOS_LOG")
((SAME_CLOCK)) && ARGS+=("--same-clock")
((AS_JSON)) && ARGS+=("--json")
exec python3 "$ANALYZER" "${ARGS[@]}"
