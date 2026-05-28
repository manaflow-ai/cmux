#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE="$REPO_ROOT/comeup/simulator-harness/ComeupSimulatorHarness.xcworkspace"
SCHEME="ComeupSimulatorHarness"
SIMULATOR_NAME="${IOS_SIMULATOR_NAME:-iPhone 17 Pro}"
TAG=""

usage() {
  cat <<'USAGE'
usage: ios/scripts/reload.sh --tag <tag> [--simulator-name <name>]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --simulator-name)
      SIMULATOR_NAME="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  printf '--tag is required\n' >&2
  usage >&2
  exit 2
fi

if [[ ! "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,11}$ ]]; then
  printf 'tag must be 1-12 characters and contain only letters, numbers, or hyphens\n' >&2
  exit 2
fi

command -v xcodebuildmcp >/dev/null

TAG_LOWER="$(printf '%s' "$TAG" | tr '[:upper:]' '[:lower:]')"
DISPLAY_NAME="cmux DEV $TAG"
BUNDLE_ID="ai.manaflow.cmux.dev.$TAG_LOWER"
SIM_DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-ios-$TAG"
DEVICE_DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-ios-$TAG-device"
DEVELOPMENT_TEAM="${IOS_DEVELOPMENT_TEAM:-7WLXT3NR37}"

extract_first_iphone_id() {
  awk '
    /iPhone/ { in_iphone = 1; next }
    in_iphone && /UDID:/ { print $2; exit }
    /^$/ { in_iphone = 0 }
  '
}

simulator_status="failed"
iphone_status="unavailable"
iphone_note=""

"$REPO_ROOT/scripts/ensure-ghosttykit.sh"

if xcodebuildmcp simulator build-and-run \
  --workspace-path "$WORKSPACE" \
  --scheme "$SCHEME" \
  --simulator-name "$SIMULATOR_NAME" \
  --use-latest-os true \
  --derived-data-path "$SIM_DERIVED_DATA" \
  --prefer-xcodebuild true \
  --extra-args "PRODUCT_DISPLAY_NAME=$DISPLAY_NAME" \
  --extra-args "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID" \
  --extra-args "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM" \
  --output text; then
  simulator_status="succeeded"
else
  simulator_status="failed"
fi

device_text="$(xcodebuildmcp device list --output text 2>&1 || true)"
iphone_id="$(printf '%s\n' "$device_text" | extract_first_iphone_id)"
if [[ -n "$iphone_id" ]]; then
  device_log="$(mktemp "${TMPDIR:-/tmp}/cmux-ios-device-reload.XXXXXX")"
  if xcodebuildmcp device build-and-run \
    --workspace-path "$WORKSPACE" \
    --scheme "$SCHEME" \
    --device-id "$iphone_id" \
    --platform iOS \
    --derived-data-path "$DEVICE_DERIVED_DATA" \
    --prefer-xcodebuild true \
    --extra-args "PRODUCT_DISPLAY_NAME=$DISPLAY_NAME" \
    --extra-args "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID" \
    --extra-args "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM" \
    --output text >"$device_log" 2>&1; then
    cat "$device_log"
    iphone_status="succeeded"
  else
    cat "$device_log"
    if grep -Fq "Build and install succeeded" "$device_log"; then
      iphone_status="succeeded"
      iphone_note="installed; launch failed because the device is locked"
    else
      iphone_status="failed"
    fi
  fi
  rm -f "$device_log"
fi

printf 'iOS tag: %s\n' "$TAG"
printf 'Simulator reload: %s\n' "$simulator_status"
printf 'iPhone reload: %s\n' "$iphone_status"
if [[ -n "$iphone_note" ]]; then
  printf 'iPhone note: %s\n' "$iphone_note"
fi
printf 'Bundle ID: %s\n' "$BUNDLE_ID"

if [[ "$simulator_status" != "succeeded" ]]; then
  exit 1
fi
