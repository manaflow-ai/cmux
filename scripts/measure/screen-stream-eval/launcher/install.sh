#!/usr/bin/env bash
# Installs CmuxScreenEvalLauncher.app (launcher.swift) in ~/Applications once. It never replaces an
# installed copy: macOS keys the console grants to this exact signed binary, so a rebuild would lose
# them. A new launcher version gets a new bundle name instead. Prints the app's path.
#   install.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
name=CmuxScreenEvalLauncher
app="$HOME/Applications/$name.app"
if [[ -x "$app/Contents/MacOS/$name" ]]; then
  echo "$app"
  exit 0
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/$name.app/Contents/MacOS"
swiftc -O -o "$work/$name.app/Contents/MacOS/$name" "$here/launcher.swift"
cat >"$work/$name.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>ai.manaflow.cmux-screen-eval-launcher</string>
  <key>CFBundleName</key><string>CmuxScreenEvalLauncher</string>
  <key>CFBundleExecutable</key><string>CmuxScreenEvalLauncher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF
codesign --force --sign - --identifier ai.manaflow.cmux-screen-eval-launcher "$work/$name.app"
mkdir -p "$HOME/Applications"
mv "$work/$name.app" "$app"
echo "$app"
