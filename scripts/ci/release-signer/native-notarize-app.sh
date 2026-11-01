#!/usr/bin/env bash
# Notarize and staple an already signed app with notarytool on an owned Mac.
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { echo "native-notarize-app requires macOS" >&2; exit 2; }
[[ $# -eq 2 ]] || { echo "usage: $0 <app-path> <log-file>" >&2; exit 2; }
APP_PATH="${1%/}"
LOG_FILE="$2"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
XCRUN_TOOL="${CMUX_XCRUN_TOOL:-xcrun}"
DITTO_TOOL="${CMUX_DITTO_TOOL:-/usr/bin/ditto}"
STAPLER_TOOL="${CMUX_STAPLER_TOOL:-xcrun}"
KEYCHAIN_TOOL="${CMUX_SIGNING_KEYCHAIN_TOOL:-$ROOT_DIR/ci/signing-keychain.sh}"
: "${ASC_API_KEY_ID:?ASC_API_KEY_ID is required}"
: "${ASC_API_ISSUER_ID:?ASC_API_ISSUER_ID is required}"
: "${ASC_API_KEY_P8_BASE64:?ASC_API_KEY_P8_BASE64 is required}"
: "${CMUX_NATIVE_NOTARY_PROFILE:?CMUX_NATIVE_NOTARY_PROFILE is required}"
: "${CMUX_NATIVE_SIGNING_KEYCHAIN:?CMUX_NATIVE_SIGNING_KEYCHAIN is required}"
[[ -d "$APP_PATH/Contents" ]] || { echo "error: app bundle not found at $APP_PATH" >&2; exit 1; }

TMP_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cmux-native-app-notary.XXXXXX")"
ZIP_PATH="$TMP_DIR/app.zip"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
source "$ROOT_DIR/ci/lib/notary-auth.sh"
CMUX_NOTARY_USE_KEYCHAIN_PROFILE=true notary_auth_init "$TMP_DIR" >&2
"$DITTO_TOOL" -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH" >&2
set +e
NOTARY_MAX_WAIT_SECONDS="${NOTARY_MAX_WAIT_SECONDS:-1200}"
[[ "$NOTARY_MAX_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "NOTARY_MAX_WAIT_SECONDS must be a positive integer" >&2; exit 2; }
submit_json="$("$XCRUN_TOOL" notarytool submit "$ZIP_PATH" "${NOTARY_AUTH_ARGS[@]}" --wait --timeout "${NOTARY_MAX_WAIT_SECONDS}s" --output-format json 2>&1)"
status=$?
set -e
printf '%s\n' "$submit_json" > "$LOG_FILE"
submission_id="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("id", ""))' <<<"$submit_json" 2>/dev/null || true)"
[[ "$submission_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || { echo "error: native app notarization returned no valid submission id" >&2; cat "$LOG_FILE" >&2; exit 1; }
printf 'submission_id=%s\n' "$submission_id"
[[ "$status" -eq 0 ]] || { echo "error: native app notarization failed" >&2; cat "$LOG_FILE" >&2; exit 1; }
notary_status="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("status", "unknown"))' <<<"$submit_json" 2>/dev/null || true)"
[[ "$notary_status" == Accepted ]] || { echo "error: native app notarization status: ${notary_status:-unknown}" >&2; cat "$LOG_FILE" >&2; exit 1; }
"$STAPLER_TOOL" stapler staple "$APP_PATH" >&2
"$STAPLER_TOOL" stapler validate "$APP_PATH" >&2
[[ -f "$APP_PATH/Contents/CodeResources" ]] || { echo "error: no stapled ticket in $APP_PATH" >&2; exit 1; }
notary_auth_forget "$TMP_DIR"
