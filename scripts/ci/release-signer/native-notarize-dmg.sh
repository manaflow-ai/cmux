#!/usr/bin/env bash
# Sign, notarize and staple a DMG with native macOS tools on an owned Mac.
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { echo "native-notarize-dmg requires macOS" >&2; exit 2; }
[[ $# -eq 1 ]] || { echo "usage: $0 <dmg-path>" >&2; exit 2; }
DMG_PATH="$1"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CODESIGN_TOOL="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"
XCRUN_TOOL="${CMUX_XCRUN_TOOL:-xcrun}"
SECURITY_TOOL="${CMUX_SECURITY_TOOL:-security}"
KEYCHAIN_TOOL="${CMUX_SIGNING_KEYCHAIN_TOOL:-$ROOT_DIR/ci/signing-keychain.sh}"
KEYCHAIN="${CMUX_NATIVE_SIGNING_KEYCHAIN:-build.keychain}"
: "${APPLE_SIGNING_IDENTITY:?APPLE_SIGNING_IDENTITY is required}"
: "${ASC_API_KEY_ID:?ASC_API_KEY_ID is required}"
: "${ASC_API_ISSUER_ID:?ASC_API_ISSUER_ID is required}"
: "${ASC_API_KEY_P8_BASE64:?ASC_API_KEY_P8_BASE64 is required}"
: "${CMUX_NATIVE_NOTARY_PROFILE:?CMUX_NATIVE_NOTARY_PROFILE is required}"
: "${CMUX_NATIVE_SIGNING_KEYCHAIN:?CMUX_NATIVE_SIGNING_KEYCHAIN is required}"
[[ -f "$DMG_PATH" ]] || { echo "error: DMG not found at $DMG_PATH" >&2; exit 1; }

"$KEYCHAIN_TOOL" unlock
# Resolve full names, unique CN substrings and SHA-1 fingerprints against only
# this job's keychain; bind the resulting signature to that exact certificate.
identities="$("$SECURITY_TOOL" find-identity -v -p codesigning "$KEYCHAIN")"
identity_name="$(IDENTITY_WANTED="$APPLE_SIGNING_IDENTITY" python3 -c '
import os,re,sys
wanted=os.environ["IDENTITY_WANTED"]
fingerprint=bool(re.fullmatch(r"[0-9a-fA-F]{40}", wanted))
matches=[]
for line in sys.stdin:
    match=re.fullmatch(r"\s*\d+\)\s+([0-9a-fA-F]{40})\s+\"([^\"]+)\"\s*", line.rstrip())
    if not match: continue
    digest,name=match.groups()
    if (digest.lower()==wanted.lower() if fingerprint else wanted in name):
        matches.append(name)
if len(matches)!=1 or not matches[0].startswith("Developer ID Application:"):
    sys.exit("identity must name exactly one Developer ID Application certificate")
print(matches[0])
' <<<"$identities")"
expected_identifier="$(basename "$DMG_PATH" .dmg)"
"$CODESIGN_TOOL" --force --timestamp --identifier "$expected_identifier" --keychain "$KEYCHAIN" --sign "$APPLE_SIGNING_IDENTITY" "$DMG_PATH"
"$CODESIGN_TOOL" --verify --verbose=2 "$DMG_PATH"
signature_info="$("$CODESIGN_TOOL" --display --verbose=4 "$DMG_PATH" 2>&1)"
authority="$(sed -n 's/^Authority=//p' <<<"$signature_info" | head -n 1)"
[[ "$authority" == "$identity_name" ]] || { echo "error: DMG signature identity mismatch" >&2; exit 1; }
team_identifier="$(sed -n 's/^TeamIdentifier=//p' <<<"$signature_info" | head -n 1)"
[[ "$team_identifier" == 7WLXT3NR37 ]] || { echo "error: DMG signature team mismatch" >&2; exit 1; }
identifier="$(sed -n 's/^Identifier=//p' <<<"$signature_info" | head -n 1)"
[[ "$identifier" == "$expected_identifier" ]] || { echo "error: DMG signature identifier mismatch" >&2; exit 1; }
grep -Eq '^CodeDirectory .*flags=0x0[(]none[)]([[:space:]]|$)' <<<"$signature_info" || { echo "error: DMG signature has unexpected flags" >&2; exit 1; }
requirement_info="$("$CODESIGN_TOOL" --display --requirements :- "$DMG_PATH" 2>&1 || true)"
grep -Fq 'designated' <<<"$requirement_info" || { echo "error: DMG signature has no designated requirement" >&2; exit 1; }
grep -Fq 'anchor apple generic' <<<"$requirement_info" || { echo "error: DMG designated requirement is not Developer ID" >&2; exit 1; }
grep -Fq '1.2.840.113635.100.6.2.6' <<<"$requirement_info" || { echo "error: DMG requirement lacks Developer ID intermediate OID" >&2; exit 1; }
grep -Fq '1.2.840.113635.100.6.1.13' <<<"$requirement_info" || { echo "error: DMG requirement lacks Developer ID Application OID" >&2; exit 1; }
grep -Fq 'certificate leaf[subject.OU] = "7WLXT3NR37"' <<<"$requirement_info" || { echo "error: DMG requirement has wrong team" >&2; exit 1; }
TMP_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cmux-native-dmg-notary.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
source "$ROOT_DIR/ci/lib/notary-auth.sh"
CMUX_NOTARY_USE_KEYCHAIN_PROFILE=true notary_auth_init "$TMP_DIR" >&2
set +e
NOTARY_MAX_WAIT_SECONDS="${NOTARY_MAX_WAIT_SECONDS:-1200}"
[[ "$NOTARY_MAX_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "NOTARY_MAX_WAIT_SECONDS must be a positive integer" >&2; exit 2; }
submit_json="$("$XCRUN_TOOL" notarytool submit "$DMG_PATH" "${NOTARY_AUTH_ARGS[@]}" --wait --timeout "${NOTARY_MAX_WAIT_SECONDS}s" --output-format json 2>&1)"
status=$?
set -e
[[ "$status" -eq 0 ]] || { echo "error: native DMG notarization failed" >&2; printf '%s\n' "$submit_json" >&2; exit 1; }
submission_id="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("id", ""))' <<<"$submit_json" 2>/dev/null || true)"
[[ "$submission_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || { echo "error: native DMG notarization returned no valid submission id" >&2; printf '%s\n' "$submit_json" >&2; exit 1; }
echo "submission ID: $submission_id"
notary_status="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("status", "unknown"))' <<<"$submit_json" 2>/dev/null || true)"
[[ "$notary_status" == Accepted ]] || { echo "error: native DMG notarization status: ${notary_status:-unknown}" >&2; printf '%s\n' "$submit_json" >&2; exit 1; }
"$XCRUN_TOOL" stapler staple "$DMG_PATH"
"$XCRUN_TOOL" stapler validate "$DMG_PATH"
notary_auth_forget "$TMP_DIR"
