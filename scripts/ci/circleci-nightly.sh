#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=./circleci-macos-release-common.sh
source "$ROOT_DIR/scripts/ci/circleci-macos-release-common.sh"

trap cmux_ci_cleanup_keychain EXIT

cmux_ci_export_github_token

FORCE_BUILD="${CMUX_FORCE_NIGHTLY:-false}"
REQUESTED_REF="${CIRCLE_BRANCH:-main}"
IS_MAIN_REF=false
if [ "${CIRCLE_TAG:-}" = "" ] && [ "$REQUESTED_REF" = "main" ]; then
  IS_MAIN_REF=true
fi

if [ "$IS_MAIN_REF" = "true" ]; then
  HEAD_SHA="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
else
  HEAD_SHA="${CIRCLE_SHA1:-$(git rev-parse HEAD)}"
fi
SHORT_SHA="$(printf "%s" "$HEAD_SHA" | cut -c1-7)"

NIGHTLY_SHA="$(git ls-remote origin 'refs/tags/nightly^{}' | awk '{print $1}' | head -n 1 || true)"
if [ -z "$NIGHTLY_SHA" ]; then
  NIGHTLY_SHA="$(git ls-remote origin refs/tags/nightly | awk '{print $1}' | head -n 1 || true)"
fi

SHOULD_BUILD=false
SHOULD_PUBLISH=false
if [ "$IS_MAIN_REF" != "true" ] || [ "$FORCE_BUILD" = "true" ] || [ "$NIGHTLY_SHA" != "$HEAD_SHA" ]; then
  SHOULD_BUILD=true
fi
if [ "$IS_MAIN_REF" = "true" ]; then
  SHOULD_PUBLISH=true
fi

cat <<EOF
Nightly build decision
requested ref: $REQUESTED_REF
build HEAD: $HEAD_SHA
nightly tag: ${NIGHTLY_SHA:-"(missing)"}
force build: $FORCE_BUILD
should build: $SHOULD_BUILD
should publish: $SHOULD_PUBLISH
EOF

if [ "$SHOULD_BUILD" != "true" ]; then
  echo "Nightly is already current, skipping."
  exit 0
fi

git fetch origin "$HEAD_SHA" --depth=1
git checkout --force "$HEAD_SHA"
git submodule sync --recursive
git submodule update --init --recursive

if [ "$SHOULD_PUBLISH" = "true" ]; then
  CURRENT_MAIN_SHA="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
  if [ "$CURRENT_MAIN_SHA" != "$HEAD_SHA" ]; then
    echo "Main moved before build. Build SHA: $HEAD_SHA, current main SHA: $CURRENT_MAIN_SHA. Skipping publish."
    exit 0
  fi
fi

cmux_ci_select_xcode
cmux_ci_install_build_deps
./scripts/download-prebuilt-ghosttykit.sh
cmux_ci_derive_sparkle_public_key

cmux_ci_build_universal_release_app AppIcon-Nightly

CMUX_APP_PATH="build-universal/Build/Products/Release/cmux.app" \
  ./tests/test_bundled_ghostty_theme_picker_helper.sh

APP_PATH="build-universal/Build/Products/Release/cmux.app"
cmux_ci_verify_binary_architectures "$APP_PATH"

CLI_BINARY="$APP_PATH/Contents/Resources/bin/cmux"
[ -x "$CLI_BINARY" ] || { echo "cmux CLI binary not found at $CLI_BINARY" >&2; exit 1; }
CMUX_CLI_BIN="$CLI_BINARY" python3 tests/test_cli_version_memory_guard.py

if [ "$SHOULD_PUBLISH" = "true" ]; then
  CURRENT_MAIN_SHA="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
  if [ "$CURRENT_MAIN_SHA" != "$HEAD_SHA" ]; then
    echo "Main moved after build. Build SHA: $HEAD_SHA, current main SHA: $CURRENT_MAIN_SHA. Skipping publish."
    exit 0
  fi
fi

APP_DIR="build-universal/Build/Products/Release"
BASE_MARKETING="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/cmux.app/Contents/Info.plist")"
NIGHTLY_BUILD="${CMUX_NIGHTLY_BUILD:-$(date -u +%Y%m%d%H%M%S)}"
NIGHTLY_MARKETING_VERSION="${BASE_MARKETING}-nightly.${NIGHTLY_BUILD}"
NIGHTLY_REMOTE_DAEMON_VERSION="$NIGHTLY_MARKETING_VERSION"
NIGHTLY_DMG_IMMUTABLE="cmux-nightly-macos-${NIGHTLY_BUILD}.dmg"
export NIGHTLY_BUILD NIGHTLY_MARKETING_VERSION NIGHTLY_REMOTE_DAEMON_VERSION NIGHTLY_DMG_IMMUTABLE

APP_PLIST="$APP_DIR/cmux.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName cmux NIGHTLY" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName cmux NIGHTLY" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.cmuxterm.app.nightly" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${SPARKLE_PUBLIC_KEY}" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://files.cmux.com/nightly/appcast.xml" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NIGHTLY_MARKETING_VERSION}" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NIGHTLY_BUILD}" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Delete :CMUXCommit" "$APP_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CMUXCommit string ${SHORT_SHA}" "$APP_PLIST"
mv "$APP_DIR/cmux.app" "$APP_DIR/cmux NIGHTLY.app"

echo "Nightly app name: cmux NIGHTLY"
echo "Nightly bundle ID: com.cmuxterm.app.nightly"
echo "Nightly marketing version: $NIGHTLY_MARKETING_VERSION"
echo "Nightly build number: $NIGHTLY_BUILD"
echo "Nightly immutable DMG: $NIGHTLY_DMG_IMMUTABLE"
echo "Commit SHA: $SHORT_SHA"

./scripts/build_remote_daemon_release_assets.sh \
  --version "$NIGHTLY_REMOTE_DAEMON_VERSION" \
  --release-tag "nightly" \
  --repo "$cmux_ci_repo" \
  --output-dir "remote-daemon-assets" \
  --asset-suffix "$NIGHTLY_BUILD"
MANIFEST_JSON="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), separators=(",",":")))' "remote-daemon-assets/cmuxd-remote-manifest-${NIGHTLY_BUILD}.json")"
NIGHTLY_APP_PLIST="$APP_DIR/cmux NIGHTLY.app/Contents/Info.plist"
plutil -remove CMUXRemoteDaemonManifestJSON "$NIGHTLY_APP_PLIST" >/dev/null 2>&1 || true
plutil -insert CMUXRemoteDaemonManifestJSON -string "$MANIFEST_JSON" "$NIGHTLY_APP_PLIST"

for platform in darwin-arm64 darwin-amd64 linux-arm64 linux-amd64; do
  cp "remote-daemon-assets/cmuxd-remote-${platform}-${NIGHTLY_BUILD}" \
     "remote-daemon-assets/cmuxd-remote-${platform}"
done
(
  cd remote-daemon-assets
  shasum -a 256 \
    cmuxd-remote-darwin-arm64 \
    cmuxd-remote-darwin-amd64 \
    cmuxd-remote-linux-arm64 \
    cmuxd-remote-linux-amd64 \
    > cmuxd-remote-checksums.txt
)
cp "remote-daemon-assets/cmuxd-remote-manifest-${NIGHTLY_BUILD}.json" \
   "remote-daemon-assets/cmuxd-remote-manifest.json"

cmux_ci_import_signing_cert

cmux_ci_require_env APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64
NIGHTLY_APP_PATH="$APP_DIR/cmux NIGHTLY.app"
PROFILE_PATH="$NIGHTLY_APP_PATH/Contents/embedded.provisionprofile"
TMP_PROFILE="$(mktemp /tmp/cmux-nightly-profile.XXXXXX)"
TMP_PLIST="$(mktemp /tmp/cmux-nightly-profile.XXXXXX.plist)"
cmux_ci_decode_base64_to_file "$APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64" "$TMP_PROFILE"
security cms -D -i "$TMP_PROFILE" > "$TMP_PLIST"
APP_ID="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$TMP_PLIST")"
if [ "$APP_ID" != "7WLXT3NR37.com.cmuxterm.app.nightly" ]; then
  echo "Nightly provisioning profile targets unexpected app ID: $APP_ID" >&2
  exit 1
fi
WEBAUTHN_ENTITLEMENT="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.web-browser.public-key-credential" "$TMP_PLIST")"
if [ "$WEBAUTHN_ENTITLEMENT" != "true" ]; then
  echo "Nightly provisioning profile is missing WebAuthn browser entitlement" >&2
  exit 1
fi
PROVISIONS_ALL_DEVICES="$(/usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$TMP_PLIST")"
if [ "$PROVISIONS_ALL_DEVICES" != "true" ]; then
  echo "Nightly provisioning profile is not a Developer ID all-devices profile" >&2
  exit 1
fi
cp "$TMP_PROFILE" "$PROFILE_PATH"
rm -f "$TMP_PROFILE" "$TMP_PLIST"

cmux_ci_require_env APPLE_SIGNING_IDENTITY
./scripts/sign-cmux-bundle.sh \
  "$NIGHTLY_APP_PATH" \
  cmux.nightly.entitlements \
  "$APPLE_SIGNING_IDENTITY"

cmux_ci_require_env APPLE_ID
cmux_ci_require_env APPLE_APP_SPECIFIC_PASSWORD
cmux_ci_require_env APPLE_TEAM_ID

notarize_and_package() {
  local app_path="$1"
  local dmg_release="$2"
  local dmg_immutable="$3"
  local zip_submit="${dmg_release%.dmg}-notary.zip"
  local dmg_tmp_dir created_dmg app_submit_json app_submit_id app_status dmg_submit_json dmg_submit_id dmg_status

  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_submit"
  app_submit_json="$(xcrun notarytool submit "$zip_submit" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait --output-format json)"
  app_submit_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$app_submit_json")"
  app_status="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$app_submit_json")"
  if [ "$app_status" != "Accepted" ]; then
    echo "App notarization failed for $app_path with status: $app_status" >&2
    xcrun notarytool log "$app_submit_id" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" || true
    exit 1
  fi
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  spctl -a -vv --type execute "$app_path"
  rm -f "$zip_submit"

  dmg_tmp_dir="$(mktemp -d)"
  create-dmg \
    --identity="$APPLE_SIGNING_IDENTITY" \
    "$app_path" \
    "$dmg_tmp_dir"
  created_dmg="$(find "$dmg_tmp_dir" -maxdepth 1 -name '*.dmg' | head -n 1)"
  if [ -z "$created_dmg" ]; then
    echo "Failed to locate created DMG for $app_path" >&2
    exit 1
  fi
  mv "$created_dmg" "$dmg_release"
  rm -rf "$dmg_tmp_dir"

  dmg_submit_json="$(xcrun notarytool submit "$dmg_release" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait --output-format json)"
  dmg_submit_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$dmg_submit_json")"
  dmg_status="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$dmg_submit_json")"
  if [ "$dmg_status" != "Accepted" ]; then
    echo "DMG notarization failed for $dmg_release with status: $dmg_status" >&2
    xcrun notarytool log "$dmg_submit_id" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" || true
    exit 1
  fi
  xcrun stapler staple "$dmg_release"
  xcrun stapler validate "$dmg_release"
  cp "$dmg_release" "$dmg_immutable"
}

notarize_and_package \
  "$NIGHTLY_APP_PATH" \
  "cmux-nightly-macos.dmg" \
  "$NIGHTLY_DMG_IMMUTABLE"

cmux_ci_upload_dsyms_to_sentry

cmux_ci_require_env SPARKLE_PRIVATE_KEY
./scripts/sparkle_generate_appcast.sh "$NIGHTLY_DMG_IMMUTABLE" nightly appcast.xml
cp appcast.xml appcast-universal.xml

if [ "$SHOULD_PUBLISH" != "true" ]; then
  echo "Branch nightly build complete. CircleCI artifacts are not published for branch nightlies."
  exit 0
fi

git config user.name "circleci[bot]"
git config user.email "circleci[bot]@users.noreply.github.com"
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${cmux_ci_repo}.git"
git tag -f nightly "$HEAD_SHA"
git push origin refs/tags/nightly --force

python3 ./scripts/prune_nightly_release_assets.py \
  --repo "$cmux_ci_repo" \
  --release-tag nightly \
  --keep-builds 100 \
  --execute

cat > /tmp/cmux-nightly-release-notes.md <<EOF
Automated nightly build for \`${SHORT_SHA}\`.

**cmux NIGHTLY** is published as a universal app:
- bundle ID \`com.cmuxterm.app.nightly\`
- feed \`appcast.xml\`
- compatibility feed \`appcast-universal.xml\` for older universal nightlies

[Download cmux-nightly-macos.dmg](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)
EOF

nightly_files=(
  "$NIGHTLY_DMG_IMMUTABLE"
  cmux-nightly-macos.dmg
  appcast.xml
  appcast-universal.xml
  remote-daemon-assets/cmuxd-remote-darwin-arm64-${NIGHTLY_BUILD}
  remote-daemon-assets/cmuxd-remote-darwin-amd64-${NIGHTLY_BUILD}
  remote-daemon-assets/cmuxd-remote-linux-arm64-${NIGHTLY_BUILD}
  remote-daemon-assets/cmuxd-remote-linux-amd64-${NIGHTLY_BUILD}
  remote-daemon-assets/cmuxd-remote-checksums-${NIGHTLY_BUILD}.txt
  remote-daemon-assets/cmuxd-remote-manifest-${NIGHTLY_BUILD}.json
  remote-daemon-assets/cmuxd-remote-darwin-arm64
  remote-daemon-assets/cmuxd-remote-darwin-amd64
  remote-daemon-assets/cmuxd-remote-linux-arm64
  remote-daemon-assets/cmuxd-remote-linux-amd64
  remote-daemon-assets/cmuxd-remote-checksums.txt
  remote-daemon-assets/cmuxd-remote-manifest.json
)

if gh release view nightly --repo "$cmux_ci_repo" >/dev/null 2>&1; then
  gh release edit nightly \
    --repo "$cmux_ci_repo" \
    --title "Nightly" \
    --prerelease \
    --notes-file /tmp/cmux-nightly-release-notes.md
else
  gh release create nightly \
    --repo "$cmux_ci_repo" \
    --title "Nightly" \
    --prerelease \
    --latest=false \
    --notes-file /tmp/cmux-nightly-release-notes.md
fi
gh release upload nightly --repo "$cmux_ci_repo" --clobber "${nightly_files[@]}"

cmux_ci_upload_appcast_to_r2 nightly true
