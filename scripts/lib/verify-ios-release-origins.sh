#!/usr/bin/env bash
set -euo pipefail

# Fail-closed artifact gate for every signed/unsigned iOS Release archive.
# TestFlight and App Store builds use the production Stack project and must
# carry only production API, Iroh broker, and presence origins. This checks the
# built Info.plist, rather than the source settings, so an accidental CI
# environment override cannot reach an upload.

usage() {
  cat <<'EOF'
Usage: scripts/lib/verify-ios-release-origins.sh --app <path>
EOF
}

APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$APP" ]] || { echo "error: --app is required" >&2; exit 2; }
[[ -d "$APP" ]] || { echo "error: iOS app does not exist: $APP" >&2; exit 1; }
PLIST="$APP/Info.plist"
[[ -f "$PLIST" ]] || { echo "error: iOS app Info.plist is missing: $PLIST" >&2; exit 1; }

read_plist() {
  local key="$1"
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || true
    return 0
  fi

  # Linux CI has no PlistBuddy. Use the OS-owned Python interpreter as a
  # read-only fallback; do not honor an arbitrary PLISTBUDDY/PATH override,
  # because the verifier is a release security gate and its parser must not be
  # replaceable by untrusted environment input.
  if [[ -x /usr/bin/python3 ]]; then
    /usr/bin/python3 - "$PLIST" "$key" <<'PY' || true
import plistlib
import sys

path, key = sys.argv[1:3]
try:
    with open(path, "rb") as handle:
        value = plistlib.load(handle)[key]
except (OSError, KeyError, TypeError, ValueError, plistlib.InvalidFileException):
    raise SystemExit(1)

if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (int, float, str)):
    print(value)
else:
    raise SystemExit(1)
PY
  fi
}

require_exact() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: production iOS artifact $label is '${actual:-<absent>}', expected '$expected'; refusing to ship staging content" >&2
    return 1
  fi
}

require_empty() {
  local label="$1"
  local actual="$2"
  if [[ -n "$actual" ]]; then
    echo "error: production iOS artifact $label is '$actual'; release artifacts cannot carry a development tag" >&2
    return 1
  fi
}

bundle_id="$(read_plist CFBundleIdentifier)"
case "$bundle_id" in
  com.cmux.app|com.cmuxterm.app.nightly|dev.cmux.app.beta|dev.cmux.app.internal|dev.cmux.app.demo) ;;
  *)
    echo "error: production iOS artifact has unexpected release bundle identifier '${bundle_id:-<absent>}'" >&2
    exit 1
    ;;
esac
require_exact "CMUXAuthEnvironment" "$(read_plist CMUXAuthEnvironment)" "production"
require_exact "CMUXApiBaseURL" "$(read_plist CMUXApiBaseURL)" "https://cmux.com"
require_exact "CMUXIrohBrokerBaseURL" "$(read_plist CMUXIrohBrokerBaseURL)" "https://cmux.com"
require_exact "CMUXPresenceBaseURL" "$(read_plist CMUXPresenceBaseURL)" "https://presence.cmux.dev"
require_empty "CMUXDevTag" "$(read_plist CMUXDevTag)"

echo "==> production iOS runtime origins verified for ${bundle_id:-unknown bundle}"
