#!/usr/bin/env bash
# nightly.yml sign-nightly-identity-legacy: "Prepare current NEXT DMG for the parallel identity".
# Moved out of the workflow verbatim to keep nightly.yml under GitHub's
# workflow file size limit; the step's env: still sets every input.
set -euo pipefail
archive="$(find prepared-in -type f -name 'cmux-prepared-app.tar.gz' -print -quit)"
mkdir -p prepared-app next-in
tar -C prepared-app -xzf "$archive"
app="prepared-app/cmux.app"
info="$app/Contents/Info.plist"
[ -f "$info" ] || { echo "prepared app has no Info.plist" >&2; exit 1; }
: "${NEXT_BUNDLE_ID:?missing NEXT bundle id}" "${NEXT_APP_NAME:?missing NEXT app name}" \
  "${NEXT_URL_SCHEME:?missing NEXT URL scheme}" "${NEXT_FEED_BASE:?missing NEXT feed base}" \
  "${NEXT_MARKETING_VERSION:?missing NEXT marketing version}" "${NEXT_COMMIT_SHORT:?missing NEXT commit}"
feed_url="${NEXT_FEED_BASE}/appcast-arm64.xml"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${NEXT_APP_NAME}" "$info"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${NEXT_APP_NAME}" "$info"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${NEXT_BUNDLE_ID}" "$info"
url_type_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:1:CFBundleURLName' "$info")"
[[ "$url_type_name" == *.auth ]] || { echo "expected auth URL type, found $url_type_name" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:1:CFBundleURLSchemes:0 ${NEXT_URL_SCHEME}" "$info"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$info" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :LSEnvironment:CMUX_AUTH_CALLBACK_SCHEME" "$info" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUX_AUTH_CALLBACK_SCHEME string ${NEXT_URL_SCHEME}" "$info"
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$info" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$info" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY}" "$info"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string ${feed_url}" "$info"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEXT_MARKETING_VERSION}" "$info"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NIGHTLY_BUILD}" "$info"
/usr/libexec/PlistBuddy -c "Delete :CMUXCommit" "$info" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CMUXCommit string ${NEXT_COMMIT_SHORT}" "$info"
python3 scripts/ci/nightly-next-guard.py feed-url "$feed_url"
mv "$app" "prepared-app/${NEXT_APP_NAME}.app"
app="prepared-app/${NEXT_APP_NAME}.app"
python3 scripts/verify_remote_daemon_release.py \
  --manifest "remote-daemon-assets/cmuxd-remote-manifest-${NIGHTLY_BUILD}.json" \
  --assets-dir remote-daemon-assets \
  --app "$app" --embed
CMUX_SIGN_MODE=all ./scripts/sign-cmux-bundle.sh \
  "$app" cmux.next-dev.entitlements "$APPLE_SIGNING_IDENTITY"
create-dmg --no-code-sign "$app" next-in
created="$(find next-in -maxdepth 1 -name '*.dmg' -print -quit)"
[ -n "$created" ] || { echo "create-dmg produced no DMG" >&2; exit 1; }
hdiutil convert "$created" -quiet -format ULMO -ov -o "next-in/${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg"
rm -f "$created"
./scripts/ci/signing-keychain.sh unlock
/usr/bin/codesign --force --timestamp --keychain build.keychain \
  --sign "$APPLE_SIGNING_IDENTITY" \
  "next-in/${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg"
/usr/bin/codesign --verify --verbose=2 \
  "next-in/${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg"
