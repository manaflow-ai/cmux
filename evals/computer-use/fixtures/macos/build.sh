#!/bin/bash
# SPDX-License-Identifier: MIT
# build.sh [OUTDIR] : compile the macOS fixture and wrap the one binary in three app bundles,
# "CU Eval Fixture" (form and lab modes), "Eval Settings" (settings mode) and "Person" (person mode),
# so each fixture role is its own app (name, bundle id) the way a deny list or an agent sees it.
# Build on a build host or in the eval VM (needs the Swift toolchain), never on a person's Mac.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/build}
mkdir -p "$out"
arch=$(uname -m)
xcrun swiftc -swift-version 5 -O -target "$arch-apple-macos14" -o "$out/cueval-fixture" "$here/main.swift"
mk() {
  local name=$1 id=$2 app="$out/$1.app"
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
  cp "$out/cueval-fixture" "$app/Contents/MacOS/cueval-fixture"
  cat > "$app/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundleExecutable</key><string>cueval-fixture</string>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
  codesign -s - --force "$app" >/dev/null 2>&1 || true
  echo "built $app"
}
mk "CU Eval Fixture" dev.cmux.cueval.fixture
mk "Eval Settings" dev.cmux.cueval.settings
mk "Person" dev.cmux.cueval.person
rm -f "$out/cueval-fixture"
