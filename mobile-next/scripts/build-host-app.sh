#!/usr/bin/env bash
# Runs on the build mini: builds cnm-host and the menu bar app bundle.
set -euo pipefail
cd "$(dirname "$0")/../Packages/CNMKit"
swift build -c release --product cnm-host 2>&1 | grep -E "error|Compiling|Build" | tail -2
swift build -c release --product CmuxNextHostApp 2>&1 | grep -E "error|Build" | tail -2
OUT="$HOME/cnm/out/mac"
rm -rf "$OUT" && mkdir -p "$OUT"
APP="$OUT/cmux Host.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/CmuxNextHostApp "$APP/Contents/MacOS/cmux Host"
cp .build/release/cnm-host "$APP/Contents/MacOS/cnm-host"
cp -R .build/release/WebRTC.framework "$APP/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/cmux Host" 2>/dev/null || true
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/cnm-host" 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>cmux Host</string>
<key>CFBundleDisplayName</key><string>cmux Host</string>
<key>CFBundleIdentifier</key><string>dev.cmux.next.native.host</string>
<key>CFBundleExecutable</key><string>cmux Host</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
(cd "$OUT" && ditto -c -k --keepParent "cmux Host.app" cmux-Host-macos.zip)
echo "OUT=$OUT/cmux-Host-macos.zip"
