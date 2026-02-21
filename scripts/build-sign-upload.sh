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

# --- Pre-flight ---
source ~/.secrets/cmuxterm.env
export SPARKLE_PRIVATE_KEY
for tool in zig xcodebuild create-dmg xcrun codesign ditto gh; do
  command -v "$tool" >/dev/null || { echo "MISSING: $tool" >&2; exit 1; }
done
echo "Pre-flight checks passed"

# --- Build GhosttyKit (if needed) ---
if [ ! -d "GhosttyKit.xcframework" ]; then
  echo "Building GhosttyKit..."
  cd ghostty && zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast && cd ..
  rm -rf GhosttyKit.xcframework
  cp -R ghostty/macos/GhosttyKit.xcframework GhosttyKit.xcframework
else
  echo "GhosttyKit.xcframework exists, skipping build"
fi

# --- Build app (Release, unsigned) ---
echo "Building app..."
rm -rf build/
xcodebuild -scheme cmux -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
echo "Build succeeded"

# --- Inject Sparkle keys ---
echo "Injecting Sparkle keys..."
SPARKLE_PUBLIC_KEY_DERIVED=$(swift scripts/derive_sparkle_public_key.swift "$SPARKLE_PRIVATE_KEY")
APP_PLIST="$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY_DERIVED" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml" "$APP_PLIST"
echo "Sparkle keys injected"

# --- Codesign ---
echo "Codesigning..."
CLI_PATH="$APP_PATH/Contents/Resources/bin/cmux"
if [ -f "$CLI_PATH" ]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" "$CLI_PATH"
fi
/usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" --deep "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
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
./scripts/sparkle_generate_appcast.sh cmux-macos.dmg "$TAG" appcast.xml

# --- Create GitHub release (if needed) and upload ---
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists"
  EXISTING_ASSETS="$(gh release view "$TAG" --json assets --jq '.assets[].name' || true)"
  HAS_CONFLICTING_ASSET="false"
  for asset in cmux-macos.dmg appcast.xml; do
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
    gh release upload "$TAG" cmux-macos.dmg appcast.xml --clobber
  else
    echo "Uploading to existing release $TAG..."
    gh release upload "$TAG" cmux-macos.dmg appcast.xml
  fi
else
  echo "Creating release $TAG and uploading..."
  gh release create "$TAG" cmux-macos.dmg appcast.xml --title "$TAG" --notes "See CHANGELOG.md for details"
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
  homepage "https://github.com/manaflow-ai/cmux"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "cmux.app"

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
