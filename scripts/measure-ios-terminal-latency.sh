#!/usr/bin/env bash
set -euo pipefail

# measure-ios-terminal-latency.sh
#
# Drives the DEBUG typing-latency + render-cadence probe
# (MobileTerminalLatencyProbeView, enabled with CMUX_LATENCY_PROBE=1) on the
# iOS simulator and prints the resulting JSON report. This is the empirical
# gate for the GhosttySurfaceView engine-actor refactor
# (https://github.com/manaflow-ai/cmux/issues/5373): capture a baseline before
# restructuring, re-run after each step, and compare.
#
# Usage:
#   scripts/measure-ios-terminal-latency.sh --label baseline [options]
#
# Options:
#   --label <name>       run label embedded in the report (required)
#   --simulator <name>   simulator device name (default: iPhone 17)
#   --samples <n>        typing keystrokes to measure (default: 120)
#   --cadence <seconds>  streaming cadence window (default: 8)
#   --skip-build         reuse the already-built app in the derived data path
#   --timeout <seconds>  max wait for the report (default: 300)
#
# The report lands in /tmp/cmux-ios-latency-<label>.json (the simulator shares
# the host filesystem). A missing report at timeout usually means the byte or
# render pipeline wedged — exactly the regression this probe exists to catch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

LABEL=""
SIMULATOR_NAME="${IOS_SIMULATOR_NAME:-iPhone 17}"
SAMPLES=120
CADENCE_SECONDS=8
SKIP_BUILD=0
TIMEOUT=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="${2:?missing value for --label}"; shift 2 ;;
    --simulator) SIMULATOR_NAME="${2:?missing value for --simulator}"; shift 2 ;;
    --samples) SAMPLES="${2:?missing value for --samples}"; shift 2 ;;
    --cadence) CADENCE_SECONDS="${2:?missing value for --cadence}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --timeout) TIMEOUT="${2:?missing value for --timeout}"; shift 2 ;;
    -h|--help) sed -n '5,28p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$LABEL" ]]; then
  echo "error: --label is required (e.g. --label baseline)" >&2
  exit 2
fi

DERIVED_DATA="/tmp/cmux-ios-latency-probe"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/cmux.app"
BUNDLE_ID="dev.cmux.ios.latencyprobe"
REPORT_PATH="/tmp/cmux-ios-latency-${LABEL}.json"

if [[ "$SKIP_BUILD" != 1 ]]; then
  ./scripts/ensure-ghosttykit.sh
  echo "==> Building cmux-ios (latency probe, derived data: $DERIVED_DATA)"
  xcodebuild \
    -workspace ios/cmux.xcworkspace \
    -scheme cmux-ios \
    -sdk iphonesimulator \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "generic/platform=iOS Simulator" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    build | tail -4
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: built app not found at $APP_PATH" >&2
  exit 1
fi

SIM_ID="$(xcrun simctl list devices available | grep -E "^\s+$SIMULATOR_NAME \(" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
if [[ -z "$SIM_ID" ]]; then
  echo "error: no available simulator named '$SIMULATOR_NAME'" >&2
  exit 1
fi

echo "==> Booting simulator $SIMULATOR_NAME ($SIM_ID)"
xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null

echo "==> Installing $APP_PATH"
xcrun simctl install "$SIM_ID" "$APP_PATH"

rm -f "$REPORT_PATH"
echo "==> Launching probe (label=$LABEL samples=$SAMPLES cadence=${CADENCE_SECONDS}s)"
xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_CMUX_LATENCY_PROBE=1 \
SIMCTL_CHILD_CMUX_LATENCY_REPORT_PATH="$REPORT_PATH" \
SIMCTL_CHILD_CMUX_LATENCY_SAMPLES="$SAMPLES" \
SIMCTL_CHILD_CMUX_LATENCY_CADENCE_SECONDS="$CADENCE_SECONDS" \
SIMCTL_CHILD_CMUX_LATENCY_PROBE_LABEL="$LABEL" \
  xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" >/dev/null

echo "==> Waiting for report at $REPORT_PATH (timeout ${TIMEOUT}s)"
waited=0
while [[ ! -s "$REPORT_PATH" ]]; do
  if (( waited >= TIMEOUT )); then
    echo "error: probe did not produce a report within ${TIMEOUT}s." >&2
    echo "       The pipeline likely wedged (the failure class this probe guards)." >&2
    exit 1
  fi
  sleep 2
  waited=$((waited + 2))
done

xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "==> Report ($REPORT_PATH):"
if command -v jq >/dev/null 2>&1; then
  jq . "$REPORT_PATH"
else
  cat "$REPORT_PATH"
fi
