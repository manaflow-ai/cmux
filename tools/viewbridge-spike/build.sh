#!/bin/bash
# Build the three throwaway VB spike binaries. Pure swiftc, no Xcode.
set -euo pipefail
cd "$(dirname "$0")"
OUT="build"
mkdir -p "$OUT"
SDK="$(xcrun --show-sdk-path)"
COMMON=(-sdk "$SDK" -O)

echo "[build] broker"
swiftc "${COMMON[@]}" src/Broker.swift -o "$OUT/broker"

echo "[build] vbservice"
swiftc "${COMMON[@]}" -framework AppKit -framework SwiftUI \
  src/Shared.swift src/service/main.swift -o "$OUT/vbservice"

echo "[build] vbhost"
swiftc "${COMMON[@]}" -framework AppKit \
  src/Shared.swift src/host/main.swift -o "$OUT/vbhost"

echo "[build] vbprobe (rung-3 bootstrap probe)"
swiftc "${COMMON[@]}" -framework AppKit \
  src/probe/main.swift -o "$OUT/vbprobe"

# Escalation rung 2: wrap vbservice in a minimal .app bundle that declares an
# NSExtension view-service configuration, so Bundle.main is a real bundle with a
# service Info dictionary that NSViewServiceApplication can validate.
echo "[build] VBService.app shell"
APP="$OUT/VBService.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT/vbservice" "$APP/Contents/MacOS/vbservice"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>vbservice</string>
  <key>CFBundleIdentifier</key><string>com.cmux.vbridge.service</string>
  <key>CFBundleName</key><string>VBService</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widget-extension</string>
    <key>NSExtensionPrincipalClass</key><string>VBServiceVC</string>
  </dict>
</dict></plist>
PLIST
# Ad-hoc sign so the bundle has a code identity (CLI child has none).
codesign --force --sign - "$APP" 2>/dev/null || echo "[build] codesign skipped"

echo "[build] done -> $OUT/"
