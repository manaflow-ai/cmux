#!/usr/bin/env bash
# Sign, notarize and staple a DMG with native macOS tools on an owned Mac.
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { echo "native-notarize-dmg requires macOS" >&2; exit 2; }
[[ $# -eq 1 ]] || { echo "usage: $0 <dmg-path>" >&2; exit 2; }
DMG_PATH="$1"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CODESIGN_TOOL="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"
XCRUN_TOOL="${CMUX_XCRUN_TOOL:-xcrun}"
KEYCHAIN_TOOL="${CMUX_SIGNING_KEYCHAIN_TOOL:-$ROOT_DIR/ci/signing-keychain.sh}"
KEYCHAIN="${CMUX_NATIVE_SIGNING_KEYCHAIN:-build.keychain}"
: "${APPLE_SIGNING_IDENTITY:?APPLE_SIGNING_IDENTITY is required}"
: "${ASC_API_KEY_ID:?ASC_API_KEY_ID is required}"
: "${ASC_API_ISSUER_ID:?ASC_API_ISSUER_ID is required}"
: "${ASC_API_KEY_P8_BASE64:?ASC_API_KEY_P8_BASE64 is required}"
: "${CMUX_NATIVE_NOTARY_PROFILE:?CMUX_NATIVE_NOTARY_PROFILE is required}"
[[ -f "$DMG_PATH" ]] || { echo "error: DMG not found at $DMG_PATH" >&2; exit 1; }

"$KEYCHAIN_TOOL" unlock
"$CODESIGN_TOOL" --force --timestamp --keychain "$KEYCHAIN" --sign "$APPLE_SIGNING_IDENTITY" "$DMG_PATH"
"$CODESIGN_TOOL" --verify --verbose=2 "$DMG_PATH"
TMP_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cmux-native-dmg-notary.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
source "$ROOT_DIR/ci/lib/notary-auth.sh"
CMUX_NOTARY_USE_KEYCHAIN_PROFILE=true notary_auth_init "$TMP_DIR"
set +e
submit_json="$("$XCRUN_TOOL" notarytool submit "$DMG_PATH" "${NOTARY_AUTH_ARGS[@]}" --wait --output-format json 2>&1)"
status=$?
set -e
[[ "$status" -eq 0 ]] || { echo "error: native DMG notarization failed" >&2; printf '%s\n' "$submit_json" >&2; exit 1; }
submission_id="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("id", ""))' <<<"$submit_json" 2>/dev/null || true)"
[[ -n "$submission_id" ]] || { echo "error: native DMG notarization returned no submission id" >&2; printf '%s\n' "$submit_json" >&2; exit 1; }
echo "submission ID: $submission_id"
notary_status="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("status", "unknown"))' <<<"$submit_json" 2>/dev/null || true)"
[[ "$notary_status" == Accepted ]] || { echo "error: native DMG notarization status: ${notary_status:-unknown}" >&2; printf '%s\n' "$submit_json" >&2; exit 1; }
"$XCRUN_TOOL" stapler staple "$DMG_PATH"
"$XCRUN_TOOL" stapler validate "$DMG_PATH"
notary_auth_forget "$TMP_DIR"
