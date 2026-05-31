#!/usr/bin/env bash
# Notarize + staple an already-Developer-ID-signed Panecho.app, producing a
# stapled DMG and a stapled zip. CREDENTIAL-FREE: this script holds no secrets.
# It reads App Store Connect API-key notarization credentials from the
# environment and never echoes them.
#
# Usage:
#   scripts/notarize-and-staple-panecho.sh <signed-app-path> <signing-identity>
#
# Required env (provided by the private signing repo / self-hosted runner — NOT
# stored in this public repo):
#   ASC_API_KEY_PATH    path to the App Store Connect API key .p8 file
#   ASC_API_KEY_ID      App Store Connect API Key ID
#   ASC_API_ISSUER_ID   App Store Connect Issuer ID
#
# Outputs (in the current directory):
#   Panecho.dmg         notarized + stapled disk image
#   panecho-macos.zip   notarized app, stapled, re-zipped
#
# Prereqs: the app must ALREADY be signed with a Developer ID Application
# identity + hardened runtime (run scripts/sign-cmux-bundle.sh first).

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <signed-app-path> <signing-identity>" >&2
  exit 2
fi

APP_PATH="$1"
IDENTITY="$2"
VOL_NAME="${PANECHO_DMG_VOLNAME:-Panecho}"
OUT_DMG="${PANECHO_OUT_DMG:-Panecho.dmg}"
OUT_ZIP="${PANECHO_OUT_ZIP:-panecho-macos.zip}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi
: "${ASC_API_KEY_PATH:?set ASC_API_KEY_PATH to the .p8 key file}"
: "${ASC_API_KEY_ID:?set ASC_API_KEY_ID}"
: "${ASC_API_ISSUER_ID:?set ASC_API_ISSUER_ID}"
if [[ ! -f "$ASC_API_KEY_PATH" ]]; then
  echo "error: ASC_API_KEY_PATH file not found: $ASC_API_KEY_PATH" >&2
  exit 1
fi

NOTARY=(--key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID")

submit_and_wait() {
  # $1 = file to notarize. Submits, waits, fails (and dumps the log) unless Accepted.
  local file="$1" json id status
  echo "==> notarizing $(basename "$file")"
  json="$(xcrun notarytool submit "$file" "${NOTARY[@]}" --wait --output-format json)"
  id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$json")"
  status="$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$json")"
  echo "    submission $id -> $status"
  if [[ "$status" != "Accepted" ]]; then
    echo "==> notarization failed; fetching log" >&2
    xcrun notarytool log "$id" "${NOTARY[@]}" || true
    exit 1
  fi
}

# 1. Notarize a zip of the signed app, then staple the app itself.
APP_ZIP_TMP="$(mktemp -d)/panecho-notarize.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$APP_ZIP_TMP"
submit_and_wait "$APP_ZIP_TMP"
echo "==> stapling app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# 2. Final stapled zip asset (re-zip the now-stapled app).
rm -f "$OUT_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUT_ZIP"
echo "==> wrote $OUT_ZIP"

# 3. Build a DMG from the stapled app, sign it, notarize it, staple it.
DMG_STAGE="$(mktemp -d)"
cp -R "$APP_PATH" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$OUT_DMG"
echo "==> building dmg"
hdiutil create -volname "$VOL_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$OUT_DMG" >/dev/null
echo "==> signing dmg"
/usr/bin/codesign --force --timestamp --sign "$IDENTITY" "$OUT_DMG"
submit_and_wait "$OUT_DMG"
echo "==> stapling dmg"
xcrun stapler staple "$OUT_DMG"
xcrun stapler validate "$OUT_DMG"

# 4. Final verification (Gatekeeper acceptance must report Notarized Developer ID).
echo "==> verifying Gatekeeper acceptance"
spctl -a -vvv -t exec "$APP_PATH"

echo "==> OK: $OUT_DMG + $OUT_ZIP notarized & stapled"
