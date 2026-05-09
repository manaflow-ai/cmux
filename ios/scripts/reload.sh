#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ios/scripts/reload.sh --tag <tag> [--simulator <name>] [--no-launch]

Build, install, and launch the cmux iOS simulator app with an isolated tag.
EOF
}

sanitize_tag() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="dev"
  fi
  echo "$cleaned"
}

TAG=""
SIMULATOR_NAME="${IOS_SIMULATOR_NAME:-iPhone 17}"
LAUNCH=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --simulator)
      SIMULATOR_NAME="${2:-}"
      shift 2
      ;;
    --no-launch)
      LAUNCH=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unexpected argument $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "error: --tag is required" >&2
  usage >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$IOS_DIR/cmuxMobile.xcworkspace"
SCHEME="cmuxMobile"
TAG_SLUG="$(sanitize_tag "$TAG")"
DISPLAY_NAME="cmux DEV $TAG"
BUNDLE_ID="dev.cmux.ios.$TAG_SLUG"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-ios-$TAG_SLUG"
DESTINATION="platform=iOS Simulator,name=$SIMULATOR_NAME"

echo "==> iOS reload starting (tag: $TAG, simulator: $SIMULATOR_NAME)"

xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  PRODUCT_DISPLAY_NAME="$DISPLAY_NAME" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/cmuxMobile.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: built app not found at $APP_PATH" >&2
  exit 1
fi

SIM_ID="$(SIMULATOR_NAME="$SIMULATOR_NAME" /usr/bin/python3 - <<'PY'
import json
import os
import subprocess
import sys

name = os.environ["SIMULATOR_NAME"]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
for runtimes in data.get("devices", {}).values():
    for device in runtimes:
        if device.get("name") == name and device.get("isAvailable", True):
            print(device["udid"])
            raise SystemExit(0)
print(f"error: simulator not found: {name}", file=sys.stderr)
raise SystemExit(1)
PY
)"

xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIM_ID" "$APP_PATH"

if [[ "$LAUNCH" -eq 1 ]]; then
  xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" >/dev/null
fi

cat <<EOF
==> iOS reload succeeded
App path:
  $APP_PATH
Bundle id:
  $BUNDLE_ID
Simulator:
  $SIMULATOR_NAME ($SIM_ID)
EOF
