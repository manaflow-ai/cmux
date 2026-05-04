#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=./circleci-macos-release-common.sh
source "$ROOT_DIR/scripts/ci/circleci-macos-release-common.sh"

trap cmux_ci_cleanup_keychain EXIT

cmux_ci_export_github_token

TAG="${CIRCLE_TAG:-${GITHUB_REF_NAME:-}}"
if [ -z "$TAG" ]; then
  echo "Release publishing requires CIRCLE_TAG or GITHUB_REF_NAME." >&2
  exit 1
fi
if [[ "$TAG" != v* ]]; then
  echo "Release tag must start with v, got: $TAG" >&2
  exit 1
fi
export GITHUB_REF_NAME="$TAG"

./tests/test_ci_sparkle_build_monotonic.sh

set +e
cmux_ci_release_asset_guard "$TAG"
guard_status=$?
set -e
case "$guard_status" in
  0) exit 0 ;;
  1) ;;
  *) exit "$guard_status" ;;
esac

cmux_ci_select_xcode
cmux_ci_install_build_deps
./scripts/download-prebuilt-ghosttykit.sh
cmux_ci_derive_sparkle_public_key

cmux_ci_build_universal_release_app
APP_PATH="build-universal/Build/Products/Release/cmux.app"
APP_PLIST="$APP_PATH/Contents/Info.plist"

cmux_ci_verify_binary_architectures "$APP_PATH"

APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST")"
./scripts/build_remote_daemon_release_assets.sh \
  --version "$APP_VERSION" \
  --release-tag "$TAG" \
  --repo "$cmux_ci_repo" \
  --output-dir "remote-daemon-assets"
MANIFEST_JSON="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), separators=(",",":")))' remote-daemon-assets/cmuxd-remote-manifest.json)"
plutil -remove CMUXRemoteDaemonManifestJSON "$APP_PLIST" >/dev/null 2>&1 || true
plutil -insert CMUXRemoteDaemonManifestJSON -string "$MANIFEST_JSON" "$APP_PLIST"

CLI_BINARY="$APP_PATH/Contents/Resources/bin/cmux"
[ -x "$CLI_BINARY" ] || { echo "cmux CLI binary not found at $CLI_BINARY" >&2; exit 1; }
CMUX_CLI_BIN="$CLI_BINARY" python3 tests/test_cli_version_memory_guard.py

HELPER_BINARY="$APP_PATH/Contents/Resources/bin/ghostty"
[ -x "$HELPER_BINARY" ] || { echo "Ghostty theme picker helper not found at $HELPER_BINARY" >&2; exit 1; }

/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${SPARKLE_PUBLIC_KEY}" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP_PLIST"

cmux_ci_import_signing_cert

cmux_ci_require_env APPLE_RELEASE_PROVISIONING_PROFILE_BASE64
PROFILE_PATH="$APP_PATH/Contents/embedded.provisionprofile"
TMP_PROFILE="$(mktemp /tmp/cmux-release-profile.XXXXXX)"
TMP_PLIST="$(mktemp /tmp/cmux-release-profile.XXXXXX.plist)"
cmux_ci_decode_base64_to_file "$APPLE_RELEASE_PROVISIONING_PROFILE_BASE64" "$TMP_PROFILE"
security cms -D -i "$TMP_PROFILE" > "$TMP_PLIST"
APP_ID="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$TMP_PLIST")"
if [ "$APP_ID" != "7WLXT3NR37.com.cmuxterm.app" ]; then
  echo "Release provisioning profile targets unexpected app ID: $APP_ID" >&2
  exit 1
fi
WEBAUTHN_ENTITLEMENT="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.web-browser.public-key-credential" "$TMP_PLIST")"
if [ "$WEBAUTHN_ENTITLEMENT" != "true" ]; then
  echo "Release provisioning profile missing WebAuthn browser entitlement" >&2
  exit 1
fi
PROVISIONS_ALL_DEVICES="$(/usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$TMP_PLIST")"
if [ "$PROVISIONS_ALL_DEVICES" != "true" ]; then
  echo "Release provisioning profile is not a Developer ID all-devices profile" >&2
  exit 1
fi
cp "$TMP_PROFILE" "$PROFILE_PATH"
rm -f "$TMP_PROFILE" "$TMP_PLIST"

cmux_ci_require_env APPLE_SIGNING_IDENTITY
./scripts/sign-cmux-bundle.sh \
  "$APP_PATH" \
  cmux.release.entitlements \
  "$APPLE_SIGNING_IDENTITY"

cmux_ci_require_env APPLE_ID
cmux_ci_require_env APPLE_APP_SPECIFIC_PASSWORD
cmux_ci_require_env APPLE_TEAM_ID

ZIP_SUBMIT="cmux-notary.zip"
DMG_RELEASE="cmux-macos.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_SUBMIT"
APP_SUBMIT_JSON="$(xcrun notarytool submit "$ZIP_SUBMIT" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait --output-format json)"
APP_SUBMIT_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$APP_SUBMIT_JSON")"
APP_STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$APP_SUBMIT_JSON")"
if [ "$APP_STATUS" != "Accepted" ]; then
  echo "App notarization failed with status: $APP_STATUS" >&2
  xcrun notarytool log "$APP_SUBMIT_ID" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" || true
  exit 1
fi
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl -a -vv --type execute "$APP_PATH"
rm -f "$ZIP_SUBMIT"

create-dmg \
  --identity="$APPLE_SIGNING_IDENTITY" \
  "$APP_PATH" \
  ./
mv ./cmux*.dmg "$DMG_RELEASE"

DMG_SUBMIT_JSON="$(xcrun notarytool submit "$DMG_RELEASE" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait --output-format json)"
DMG_SUBMIT_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$DMG_SUBMIT_JSON")"
DMG_STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$DMG_SUBMIT_JSON")"
if [ "$DMG_STATUS" != "Accepted" ]; then
  echo "DMG notarization failed with status: $DMG_STATUS" >&2
  xcrun notarytool log "$DMG_SUBMIT_ID" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" || true
  exit 1
fi
xcrun stapler staple "$DMG_RELEASE"
xcrun stapler validate "$DMG_RELEASE"

cmux_ci_upload_dsyms_to_sentry

cmux_ci_require_env SPARKLE_PRIVATE_KEY
./scripts/sparkle_generate_appcast.sh "$DMG_RELEASE" "$TAG" appcast.xml

release_files=(
  cmux-macos.dmg
  appcast.xml
  remote-daemon-assets/cmuxd-remote-darwin-arm64
  remote-daemon-assets/cmuxd-remote-darwin-amd64
  remote-daemon-assets/cmuxd-remote-linux-arm64
  remote-daemon-assets/cmuxd-remote-linux-amd64
  remote-daemon-assets/cmuxd-remote-checksums.txt
  remote-daemon-assets/cmuxd-remote-manifest.json
)

if gh release view "$TAG" --repo "$cmux_ci_repo" >/dev/null 2>&1; then
  gh release upload "$TAG" --repo "$cmux_ci_repo" "${release_files[@]}"
else
  gh release create "$TAG" --repo "$cmux_ci_repo" --title "$TAG" --generate-notes "${release_files[@]}"
fi

latest="$(gh release list --repo "$cmux_ci_repo" --exclude-drafts --exclude-pre-releases --json tagName -q '.[].tagName' | sort -V | tail -1)"
if [ -n "$latest" ] && [ "$latest" != "$TAG" ]; then
  echo "Skipping R2 stable upload: $TAG is not the latest release ($latest)"
else
  cmux_ci_upload_appcast_to_r2 stable true
fi
