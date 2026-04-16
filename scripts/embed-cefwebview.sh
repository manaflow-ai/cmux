#!/usr/bin/env bash
# Embed CEFWebView's Chromium framework + helper apps into a built cmux.app.
#
# Usage: scripts/embed-cefwebview.sh <path-to-app-bundle>
#
# Run after xcodebuild produces cmux.app but before launch. Idempotent —
# safe to re-run.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <path-to-app-bundle>" >&2
  exit 1
fi

APP="$1"
[ -d "$APP" ] || { echo "❌ App bundle not found: $APP" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_ROOT="$REPO_ROOT/vendor/CEFWebView"
PKG_FRAMEWORKS="$PKG_ROOT/Frameworks"
APP_FRAMEWORKS="$APP/Contents/Frameworks"

# 1. Make sure CEF binaries + libcef_dll_wrapper.a are built.
if [ ! -d "$PKG_FRAMEWORKS/Chromium Embedded Framework.framework" ]; then
  echo "==> Bootstrapping CEFWebView Frameworks/ (one-time, slow)"
  "$REPO_ROOT/scripts/setup-cefwebview.sh"
fi

# 2. Build SPM helper executables.
echo "==> Building CEFHelper + CEFHelperRenderer (release)"
swift build --package-path "$PKG_ROOT" -c release --product CEFHelper >/dev/null
swift build --package-path "$PKG_ROOT" -c release --product CEFHelperRenderer >/dev/null
HELPER_BUILD_DIR="$PKG_ROOT/.build/arm64-apple-macosx/release"
HELPER_BIN="$HELPER_BUILD_DIR/CEFHelper"
RENDERER_BIN="$HELPER_BUILD_DIR/CEFHelperRenderer"
[ -x "$HELPER_BIN" ] || { echo "❌ Missing $HELPER_BIN" >&2; exit 1; }
[ -x "$RENDERER_BIN" ] || { echo "❌ Missing $RENDERER_BIN" >&2; exit 1; }

mkdir -p "$APP_FRAMEWORKS"

# 3. Copy Chromium Embedded Framework.framework, then repair symlinks.
echo "==> Embedding Chromium Embedded Framework.framework"
rm -rf "$APP_FRAMEWORKS/Chromium Embedded Framework.framework"
cp -R "$PKG_FRAMEWORKS/Chromium Embedded Framework.framework" "$APP_FRAMEWORKS/"

FW_PATH="$APP_FRAMEWORKS/Chromium Embedded Framework.framework"
(
  cd "$FW_PATH"
  rm -f "Chromium Embedded Framework" Resources Libraries
  ln -sf "Versions/Current/Chromium Embedded Framework" "Chromium Embedded Framework"
  ln -sf "Versions/Current/Resources" "Resources"
  if [ -d "Versions/A/Libraries" ]; then
    ln -sf "Versions/Current/Libraries" "Libraries"
  fi
  if [ -d "Versions/Current" ] && [ ! -L "Versions/Current" ]; then
    rm -rf "Versions/Current"
    ln -s "A" "Versions/Current"
  fi
)

# 4. Build helper app bundles. CEFWrapper.mm hardcodes the name
# "WebView Helper.app" relative to Contents/Frameworks/.
make_helper_app() {
  local app_path="$1"
  local exec_name="$2"
  local source_bin="$3"
  local bundle_id="$4"

  rm -rf "$app_path"
  mkdir -p "$app_path/Contents/MacOS"
  cp "$source_bin" "$app_path/Contents/MacOS/$exec_name"
  chmod +x "$app_path/Contents/MacOS/$exec_name"

  cat > "$app_path/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$exec_name</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$exec_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF
}

echo "==> Building WebView Helper.app + WebView Helper (Renderer).app"
make_helper_app "$APP_FRAMEWORKS/WebView Helper.app" \
                "WebView Helper" \
                "$HELPER_BIN" \
                "com.cmuxterm.app.helper"
make_helper_app "$APP_FRAMEWORKS/WebView Helper (Renderer).app" \
                "WebView Helper" \
                "$RENDERER_BIN" \
                "com.cmuxterm.app.helper.renderer"

# 5. Inside-out ad-hoc sign helpers + framework + host app.
# Local DEV builds: ad-hoc only (no Developer ID identity needed). Never use
# --deep — it would overwrite the CLI helper signatures inside the host app
# and trigger amfi rejection (errno 163) on macOS 26 Tahoe.
SIGN_ID="-"
HELPER_ENTITLEMENTS="$REPO_ROOT/cmux-helper.entitlements"

echo "==> Signing CEF framework + helpers (ad-hoc)"
# Sign nested executables inside framework first (Versions/A/Helpers/* if any).
find "$APP_FRAMEWORKS/Chromium Embedded Framework.framework/Versions/A" \
     -type f -perm -u+x ! -name '*.dylib' 2>/dev/null \
     | while read -r f; do
       codesign --force --sign "$SIGN_ID" "$f" >/dev/null 2>&1 || true
     done
# Sign the framework itself.
codesign --force --sign "$SIGN_ID" \
         "$APP_FRAMEWORKS/Chromium Embedded Framework.framework" >/dev/null

# Sign helper executables, then their bundles. Helper exec names are literal
# "WebView Helper" (CEFWrapper.mm hardcodes this).
codesign --force --sign "$SIGN_ID" --options runtime \
         --entitlements "$HELPER_ENTITLEMENTS" \
         "$APP_FRAMEWORKS/WebView Helper.app/Contents/MacOS/WebView Helper" >/dev/null
codesign --force --sign "$SIGN_ID" --options runtime \
         --entitlements "$HELPER_ENTITLEMENTS" \
         "$APP_FRAMEWORKS/WebView Helper.app" >/dev/null
codesign --force --sign "$SIGN_ID" --options runtime \
         --entitlements "$HELPER_ENTITLEMENTS" \
         "$APP_FRAMEWORKS/WebView Helper (Renderer).app/Contents/MacOS/WebView Helper" >/dev/null
codesign --force --sign "$SIGN_ID" --options runtime \
         --entitlements "$HELPER_ENTITLEMENTS" \
         "$APP_FRAMEWORKS/WebView Helper (Renderer).app" >/dev/null

# Re-seal the host app so the new Contents/Frameworks/ entries are in
# CodeResources. No --deep, no host-level entitlements (DEV bundle was
# originally signed ad-hoc with no entitlements).
echo "==> Re-sealing host app (ad-hoc, no --deep)"
codesign --force --sign "$SIGN_ID" "$APP" >/dev/null

echo "✅ CEF embed complete."
