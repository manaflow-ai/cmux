#!/bin/bash
# Xcode build phase: embeds the CEF framework and helper bundles into the app.
#
# The framework comes from the machine-wide cache maintained by
# scripts/ensure-cef.sh; nothing CEF-related is checked into the repository.
# Helpers use fixed names ("cmux CEF Helper*") because the shim points
# CefSettings.browser_subprocess_path at them, keeping tagged dev builds with
# per-tag product names working unchanged.
set -euo pipefail

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
FRAMEWORK_SOURCE="$(CMUX_CEF_ARCH="${ARCHS%% *}" "$SRCROOT/scripts/ensure-cef.sh")"

APP_FRAMEWORKS="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Frameworks"
mkdir -p "$APP_FRAMEWORKS"
HELPER_CACHE_DIR="${DERIVED_FILE_DIR:-$TMPDIR}/cmux-cef-helper"
mkdir -p "$HELPER_CACHE_DIR"

# ditto, not rsync: Apple's tool copies the framework tree faithfully on
# every macOS release. The copy is skipped when the cached source is already
# mirrored (marker matches), because the framework is ~400MB.
#
# The location is not negotiable: Chromium resolves its resources and child
# processes relative to <app>/Contents/Frameworks/Chromium Embedded
# Framework.framework and CHECK-fails at initialize when moved.
DEST="$APP_FRAMEWORKS/Chromium Embedded Framework.framework"
# The marker lives outside the bundle: loose files under Frameworks/ fail
# the app's code signing.
MARKER="$HELPER_CACHE_DIR/.cef-source"
if [[ ! -d "$DEST" || "$(cat "$MARKER" 2>/dev/null)" != "$FRAMEWORK_SOURCE" \
      || ! -e "$DEST/Versions/Current/Resources/Info.plist" ]]; then
  rm -rf "$DEST" "$APP_FRAMEWORKS/ChromiumEmbedded"
  ditto "$FRAMEWORK_SOURCE" "$DEST"
  printf '%s' "$FRAMEWORK_SOURCE" > "$MARKER"
fi

# Compile the helper binary once per toolchain/source change.
HELPER_SOURCE="$SRCROOT/Packages/macOS/CmuxCEF/Helper/helper_main.c"
HELPER_INCLUDES="$SRCROOT/Packages/macOS/CmuxCEF/Sources/CmuxCEFShim/cef"
# The phase shell can run under Rosetta; pin the helper to the build arch.
HELPER_ARCH="${ARCHS%% *}"
HELPER_ARCH="${HELPER_ARCH:-$(uname -m)}"
HELPER_BINARY="$HELPER_CACHE_DIR/cmux-cef-helper-$HELPER_ARCH"
if [[ ! -x "$HELPER_BINARY" || "$HELPER_SOURCE" -nt "$HELPER_BINARY" ]]; then
  xcrun clang -O2 -mmacosx-version-min=14.0 -arch "$HELPER_ARCH" \
    -I"$HELPER_INCLUDES" \
    -Wl,-undefined,dynamic_lookup \
    -o "$HELPER_BINARY" "$HELPER_SOURCE"
fi

SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"

make_helper() {
  local suffix="$1" idsuffix="$2"
  local name="cmux CEF Helper${suffix}"
  local bundle="$APP_FRAMEWORKS/${name}.app"
  mkdir -p "$bundle/Contents/MacOS"
  cp -f "$HELPER_BINARY" "$bundle/Contents/MacOS/${name}"
  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>${name}</string>
  <key>CFBundleIdentifier</key><string>${PRODUCT_BUNDLE_IDENTIFIER}.cef-helper${idsuffix}</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSBackgroundOnly</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
  codesign --force --sign "$SIGN_IDENTITY" "$bundle"
}

make_helper "" ""
make_helper " (GPU)" ".gpu"
make_helper " (Renderer)" ".renderer"
make_helper " (Plugin)" ".plugin"
make_helper " (Alerts)" ".alerts"

# The app's CodeSign step requires every nested framework to be signed.
# Re-signing the ~400MB framework dominates incremental builds, so it is
# skipped while the existing signature still verifies.
if ! codesign --verify "$DEST" >/dev/null 2>&1; then
  codesign --force --sign "$SIGN_IDENTITY" "$DEST"
fi
if [[ ! -e "$DEST/Versions/Current/Resources/Info.plist" ]]; then
  echo "embed-cef: framework copy is malformed (no versioned Info.plist)" >&2
  exit 1
fi
echo "embed-cef: framework and helpers embedded"
