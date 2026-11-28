#!/usr/bin/env bash
# Builds the launch floor app (FloorApp.swift) for the simulator: one swiftc call, no Xcode project.
#   bash scripts/measure/ios-launch-floor/build.sh OUT_DIR   -> OUT_DIR/CmuxLaunchFloor.app
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?usage: build.sh OUT_DIR}"
app="$out/CmuxLaunchFloor.app"
mkdir -p "$app"
arch="$(uname -m)"
xcrun -sdk iphonesimulator swiftc -O -parse-as-library -target "$arch-apple-ios17.0-simulator" \
  "$here/FloorApp.swift" -o "$app/CmuxLaunchFloor"
plist="$app/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string dev.cmux.launchfloor" \
  -c "Add :CFBundleExecutable string CmuxLaunchFloor" -c "Add :CFBundleName string CmuxLaunchFloor" \
  -c "Add :CFBundlePackageType string APPL" -c "Add :CFBundleVersion string 1" \
  -c "Add :CFBundleShortVersionString string 1.0" -c "Add :MinimumOSVersion string 17.0" \
  -c "Add :CFBundleSupportedPlatforms array" -c "Add :CFBundleSupportedPlatforms:0 string iPhoneSimulator" \
  -c "Add :UIDeviceFamily array" -c "Add :UIDeviceFamily:0 integer 1" \
  -c "Add :UILaunchScreen dict" -c "Add :UIApplicationSceneManifest dict" \
  -c "Add :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes bool false" "$plist" >/dev/null
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "$app"
