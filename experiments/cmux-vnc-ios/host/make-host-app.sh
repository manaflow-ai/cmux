#!/bin/bash
# Wraps the release cmux-vnc-host binary as CmuxScreenHost.app, so macOS can
# hold its Screen Recording and Accessibility permissions (they attach to an
# app's identity, not to a bare binary launched from a shell).
#   make-host-app.sh <package dir> <output dir>
set -euo pipefail
PACKAGE="${1:?package dir}"; OUT="${2:?output dir}"
BINDIR="$(cd "$PACKAGE" && swift build -c release --product cmux-vnc-host >/dev/null && swift build -c release --show-bin-path)"
APP="$OUT/CmuxScreenHost.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BINDIR/cmux-vnc-host" "$APP/Contents/MacOS/CmuxScreenHost"
# libwebrtc ships as a framework; the app loads it from Contents/Frameworks.
ditto "$BINDIR/WebRTC.framework" "$APP/Contents/Frameworks/WebRTC.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/CmuxScreenHost" 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.cmux.screenhost</string>
  <key>CFBundleName</key><string>cmux Screen Host</string>
  <key>CFBundleExecutable</key><string>CmuxScreenHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Frameworks/WebRTC.framework"
codesign --force --sign - --identifier dev.cmux.screenhost "$APP"
echo "$APP"
