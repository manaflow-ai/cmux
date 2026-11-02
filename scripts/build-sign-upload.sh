#!/usr/bin/env bash
set -euo pipefail

# Build, sign, notarize, create DMG, generate appcast, and upload to GitHub release.
# Usage: ./scripts/build-sign-upload.sh <tag> [--allow-overwrite]
# Requires: source ~/.secrets/cmuxterm.env && export SPARKLE_PRIVATE_KEY

usage() {
  cat <<'EOF'
Usage: ./scripts/build-sign-upload.sh <tag> [--allow-overwrite]

Options:
  --allow-overwrite   Permit replacing existing release assets for the same tag.
                      Use only for emergency rerolls.
EOF
}

ALLOW_OVERWRITE="false"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-overwrite)
      ALLOW_OVERWRITE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 1
fi

TAG="$1"
SIGN_HASH="A050CC7E193C8221BDBA204E731B046CDCCC1B30"
ENTITLEMENTS="cmux.entitlements"
APP_PATH="build/Build/Products/Release/cmux.app"
GHOSTTYKIT_CRASH_REPORT_SUBDIR="cmux/crash"

# --- Pre-flight ---
source ~/.secrets/cmuxterm.env
export SPARKLE_PRIVATE_KEY
for tool in zig xcodebuild create-dmg xcrun codesign ditto gh; do
  command -v "$tool" >/dev/null || { echo "MISSING: $tool" >&2; exit 1; }
done
echo "Pre-flight checks passed"

# --- Build GhosttyKit ---
echo "Building GhosttyKit..."
rm -rf GhosttyKit.xcframework ghostty/macos/GhosttyKit.xcframework
(
  cd ghostty
  zig build -Dcrash-report-subdir="$GHOSTTYKIT_CRASH_REPORT_SUBDIR" -Dsentry=false -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=universal -Doptimize=ReleaseFast
)
cp -R ghostty/macos/GhosttyKit.xcframework GhosttyKit.xcframework

# --- Build app (Release, unsigned) ---
# The Embed CEF phase embeds the pinned Chromium engine when the private
# manaflow-ai/cef release is readable (gh login or GH_TOKEN), else the app
# ships the browser as unavailable.
echo "Building app..."
rm -rf build/
# The cmux-tui client of this commit's own tree, as release.yml installs it
# (cx-urd.9.1): resolve-exact waits for the tree's publication and prints the
# publishing commit whose attested manifest carries it. Never another commit's daemon.
CMUX_TUI_RESOLVED="$(./scripts/cmux-next/pin-cmux-tui.sh resolve-exact)"
CMUX_TUI_COMMIT="$(sed -n 's/^commit=//p' <<<"$CMUX_TUI_RESOLVED")"
CMUX_TUI_KEY="$(sed -n 's/^key=//p' <<<"$CMUX_TUI_RESOLVED")"
[[ "$CMUX_TUI_COMMIT" =~ ^[0-9a-f]{40}$ && "$CMUX_TUI_KEY" =~ ^[0-9a-f]{40}$ ]] || {
  echo "error: pin-cmux-tui.sh resolve-exact printed no commit/key" >&2; exit 1; }
# THIRD_PARTY_LICENSES.md for this commit's cmux-tui (tree mode, lock closures:
# no cargo on a maintainer's Mac); the committed copy is restored afterwards,
# which also drops any uncommitted local edit to that file.
NOTICES_ROOT="$PWD"
trap 'git -C "$NOTICES_ROOT" checkout -- THIRD_PARTY_LICENSES.md' EXIT
./scripts/cmux-next/generate-third-party-notices.sh --tui-source tree
# cmux-next's web bundles are build output (cx-vn5): a release builds them from this
# commit's sources, never from a stamp.
if [[ -x scripts/cmux-next/build-web-bundles.sh ]]; then
  scripts/cmux-next/build-web-bundles.sh --force
fi
# The Bundle cmux-tui phase bundles none (deferred); this tree's client is installed below.
CMUX_NEXT_TUI_MODE=deferred xcodebuild -scheme cmux -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
echo "Build succeeded"
if [ ! -d "$APP_PATH/Contents/Frameworks/Chromium Embedded Framework.framework" ]; then
  echo "WARNING: no Chromium engine embedded; this release ships the browser as unavailable" >&2
fi
# Chromium's license notices must ship with the engine (passes when no CEF is embedded).
./scripts/cmux-next/check-cef-credits.sh "$APP_PATH"
# An app built for the fleet benches keeps the debug.* commands; it never ships.
./scripts/cmux-next/check-no-bench-hooks.sh "$APP_PATH"

# The universal cmux-tui client of this commit's tree, as release.yml installs it.
./scripts/install-cmux-tui-client.sh "$APP_PATH" \
  --manifest-url "https://files.cmux.com/cmux-tui/${CMUX_TUI_COMMIT}/manifest.json" \
  --expected-commit "$CMUX_TUI_COMMIT" \
  --require-capability wireguard-hub
./scripts/cmux-next/write-cmux-tui-version.sh "$APP_PATH" "$CMUX_TUI_COMMIT" "$CMUX_TUI_KEY"
# The bundled daemon must serve every capability the app relies on.
./scripts/cmux-next/check-daemon-capabilities.sh --binary "$APP_PATH/Contents/Resources/bin/cmux-tui"

# The cmux-next target does not build the Ghostty CLI helper (theme picker);
# release.yml and nightly.yml inject a prebuilt one, this script builds it.
HELPER_PATH="$APP_PATH/Contents/Resources/bin/ghostty"
./scripts/build-ghostty-cli-helper.sh --universal --output "$HELPER_PATH"
if [ ! -x "$HELPER_PATH" ]; then
  echo "Ghostty theme picker helper not found at $HELPER_PATH" >&2
  exit 1
fi

# --- Inject Sparkle keys ---
echo "Injecting Sparkle keys..."
SPARKLE_PUBLIC_KEY_DERIVED=$(
  printf '%s' "$SPARKLE_PRIVATE_KEY" |
    env -u SPARKLE_PRIVATE_KEY swift scripts/derive_sparkle_public_key.swift --stdin
)
APP_PLIST="$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY_DERIVED" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml" "$APP_PLIST"
echo "Sparkle keys injected"

# cmux is a non-sandboxed app. Sparkle's sandbox-only XPC services make the
# installer handoff wait for an agent connection that never arrives.
./scripts/remove-sparkle-sandbox-xpc-services.sh "$APP_PATH"

# --- Codesign ---
echo "Codesigning..."
./scripts/sign-cmux-bundle.sh "$APP_PATH" "$ENTITLEMENTS" "$SIGN_HASH"
echo "Codesign verified"

# --- Notarize app ---
echo "Notarizing app..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" cmux-notary.zip
xcrun notarytool submit cmux-notary.zip \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
rm -f cmux-notary.zip
echo "App notarized"

# --- Create and notarize DMG ---
echo "Creating DMG..."
./scripts/verify-app-bundle-licenses.sh "$APP_PATH"
rm -f cmux-macos.dmg
create-dmg --codesign "$SIGN_HASH" cmux-macos.dmg "$APP_PATH"
echo "Notarizing DMG..."
xcrun notarytool submit cmux-macos.dmg \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
xcrun stapler staple cmux-macos.dmg
xcrun stapler validate cmux-macos.dmg
echo "DMG notarized"

# --- Generate Sparkle appcast ---
echo "Generating appcast..."
SPARKLE_MINIMUM_SYSTEM_VERSION="$(python3 ./scripts/ci/appcast_minimum_system_version.py floor "$APP_PATH")"
export SPARKLE_MINIMUM_SYSTEM_VERSION
if [[ -f scripts/cmux-next/legacy-appcast-item.xml ]]; then
  export SPARKLE_LEGACY_APPCAST_ITEM_FILE=scripts/cmux-next/legacy-appcast-item.xml
fi
./scripts/sparkle_generate_appcast.sh cmux-macos.dmg "$TAG" appcast.xml
# Stable installs from CI releases are thin and read appcast-<arch>.xml. This
# script builds only the universal DMG, so both per-arch feeds carry the
# universal item: thin installs update to it, and the next CI release moves
# them back onto their architecture.
cp appcast.xml appcast-arm64.xml
cp appcast.xml appcast-x86_64.xml

# --- Create GitHub release (if needed) and upload ---
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists"
  EXISTING_ASSETS="$(gh release view "$TAG" --json assets --jq '.assets[].name' || true)"
  HAS_CONFLICTING_ASSET="false"
  for asset in cmux-macos.dmg appcast.xml appcast-arm64.xml appcast-x86_64.xml; do
    if printf '%s\n' "$EXISTING_ASSETS" | grep -Fxq "$asset"; then
      HAS_CONFLICTING_ASSET="true"
      break
    fi
  done

  if [[ "$HAS_CONFLICTING_ASSET" == "true" && "$ALLOW_OVERWRITE" != "true" ]]; then
    echo "ERROR: Refusing to overwrite signed release assets for existing tag $TAG." >&2
    echo "Use a new tag, or rerun with --allow-overwrite for an emergency reroll." >&2
    exit 1
  fi

  if [[ "$ALLOW_OVERWRITE" == "true" ]]; then
    echo "Uploading with overwrite enabled for existing release $TAG..."
    gh release upload "$TAG" cmux-macos.dmg appcast.xml appcast-arm64.xml appcast-x86_64.xml --clobber
  else
    echo "Uploading to existing release $TAG..."
    gh release upload "$TAG" cmux-macos.dmg appcast.xml appcast-arm64.xml appcast-x86_64.xml
  fi
else
  echo "Creating release $TAG and uploading..."
  gh release create "$TAG" cmux-macos.dmg appcast.xml appcast-arm64.xml appcast-x86_64.xml --title "$TAG" --notes "See CHANGELOG.md for details"
fi

# --- Verify ---
gh release view "$TAG"

# --- Update Homebrew cask (skip for nightlies) ---
if [[ "$TAG" != *"-nightly"* ]]; then
  VERSION="${TAG#v}"
  DMG_SHA256=$(shasum -a 256 cmux-macos.dmg | cut -d' ' -f1)
  echo "Updating homebrew cask to $VERSION (SHA: $DMG_SHA256)..."
  CASK_FILE="homebrew-cmux/Casks/cmux.rb"
  if [ -f "$CASK_FILE" ]; then
    cat > "$CASK_FILE" << CASKEOF
cask "cmux" do
  version "${VERSION}"
  sha256 "${DMG_SHA256}"

  url "https://github.com/manaflow-ai/cmux/releases/download/v#{version}/cmux-macos.dmg"
  name "cmux"
  desc "Lightweight native macOS terminal with vertical tabs for AI coding agents"
  homepage "https://cmux.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "cmux.app"
  binary "#{appdir}/cmux.app/Contents/Resources/bin/cmux"
  generate_completions_from_executable "#{HOMEBREW_PREFIX}/bin/cmux", "completion"

  zap trash: [
    "~/Library/Application Support/cmux",
    "~/Library/Caches/cmux",
    "~/Library/Preferences/ai.manaflow.cmuxterm.plist",
  ]
end
CASKEOF
    cd homebrew-cmux
    git add Casks/cmux.rb
    if git diff --staged --quiet; then
      echo "Homebrew cask already up to date"
    else
      git commit -m "Update cmux to ${VERSION}"
      git push
      echo "Homebrew cask updated"
    fi
    cd ..
  else
    echo "WARNING: homebrew-cmux submodule not found, skipping cask update"
  fi
fi

# --- Cleanup ---
rm -rf build/ cmux-macos.dmg appcast.xml
echo ""
echo "=== Release $TAG complete ==="
say "cmux release complete"
