#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/lib/verify-iroh-release-gate-builds.sh \
  --mac-app <path> --ios-app <path> \
  --backend-base-url <url> [--presence-base-url <url>]
EOF
}

MAC_APP=""
IOS_APP=""
BACKEND_BASE_URL=""
PRESENCE_BASE_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mac-app) MAC_APP="${2:-}"; shift 2 ;;
    --ios-app) IOS_APP="${2:-}"; shift 2 ;;
    --backend-base-url) BACKEND_BASE_URL="${2:-}"; shift 2 ;;
    --presence-base-url) PRESENCE_BASE_URL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$MAC_APP" ]] || { echo "error: --mac-app is required" >&2; exit 2; }
[[ -n "$IOS_APP" ]] || { echo "error: --ios-app is required" >&2; exit 2; }
[[ -n "$BACKEND_BASE_URL" ]] || {
  echo "error: --backend-base-url is required" >&2
  exit 2
}

MAC_INFO_PLIST="$MAC_APP/Contents/Info.plist"
IOS_INFO_PLIST="$IOS_APP/Info.plist"
[[ -f "$MAC_INFO_PLIST" ]] || {
  echo "error: Mac app Info.plist is missing" >&2
  exit 1
}
[[ -f "$IOS_INFO_PLIST" ]] || {
  echo "error: iOS app Info.plist is missing" >&2
  exit 1
}

read_plist() {
  local plist="$1"
  local key_path="$2"
  /usr/libexec/PlistBuddy -c "Print :$key_path" "$plist" 2>/dev/null || true
}

require_value() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: $label does not contain the requested backend; rebuild without --skip-build" >&2
    return 1
  fi
}

require_value \
  "Mac app API configuration" \
  "$(read_plist "$MAC_INFO_PLIST" "LSEnvironment:CMUX_API_BASE_URL")" \
  "$BACKEND_BASE_URL"
require_value \
  "Mac app Iroh broker configuration" \
  "$(read_plist "$MAC_INFO_PLIST" "LSEnvironment:CMUX_IROH_BROKER_BASE_URL")" \
  "$BACKEND_BASE_URL"
require_value \
  "iOS app API configuration" \
  "$(read_plist "$IOS_INFO_PLIST" "CMUXApiBaseURL")" \
  "$BACKEND_BASE_URL"
require_value \
  "iOS app Iroh broker configuration" \
  "$(read_plist "$IOS_INFO_PLIST" "CMUXIrohBrokerBaseURL")" \
  "$BACKEND_BASE_URL"

if [[ -n "$PRESENCE_BASE_URL" ]]; then
  require_value \
    "Mac app presence configuration" \
    "$(read_plist "$MAC_INFO_PLIST" "LSEnvironment:CMUX_PRESENCE_BASE_URL")" \
    "$PRESENCE_BASE_URL"
  require_value \
    "iOS app presence configuration" \
    "$(read_plist "$IOS_INFO_PLIST" "CMUXPresenceBaseURL")" \
    "$PRESENCE_BASE_URL"
fi

echo "==> release-gate Mac and iOS backend artifacts verified"
