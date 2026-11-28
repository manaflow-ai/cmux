#!/usr/bin/env bash
# Builds the launch floor app (FloorApp.swift) for the simulator: one swiftc call, no Xcode project.
#   bash scripts/measure/ios-launch-floor/build.sh OUT_DIR   -> OUT_DIR/CmuxLaunchFloor.app
#   bash scripts/measure/ios-launch-floor/build.sh OUT_DIR PATH/WebRTC.framework
#     -> OUT_DIR/CmuxLaunchFloorWebRTC.app: the same floor with cmux's WebRTC.framework embedded and loaded at
#        launch (-needed_framework keeps the load with no symbol used), so its main minus the floor's is
#        WebRTC's own pre-main cost.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?usage: build.sh OUT_DIR [WebRTC.framework]}"
webrtc="${2:-}"
name=CmuxLaunchFloor
bundle_id=dev.cmux.launchfloor
link=()
if [[ -n "$webrtc" ]]; then
  [[ -d "$webrtc" ]] || { echo "build.sh: no framework at $webrtc" >&2; exit 2; }
  name=CmuxLaunchFloorWebRTC
  bundle_id=dev.cmux.launchfloor.webrtc
  link=(-F "$(dirname "$webrtc")" -Xlinker -needed_framework -Xlinker WebRTC
        -Xlinker -rpath -Xlinker @executable_path/Frameworks)
fi
app="$out/$name.app"
mkdir -p "$app"
arch="$(uname -m)"
xcrun -sdk iphonesimulator swiftc -O -parse-as-library -target "$arch-apple-ios17.0-simulator" \
  "$here/FloorApp.swift" ${link[@]+"${link[@]}"} -o "$app/$name"
if [[ -n "$webrtc" ]]; then
  mkdir -p "$app/Frameworks"
  cp -R "$webrtc" "$app/Frameworks/"
  codesign --force --sign - "$app/Frameworks/WebRTC.framework" >/dev/null 2>&1 || true
fi
plist="$app/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" \
  -c "Add :CFBundleExecutable string $name" -c "Add :CFBundleName string $name" \
  -c "Add :CFBundlePackageType string APPL" -c "Add :CFBundleVersion string 1" \
  -c "Add :CFBundleShortVersionString string 1.0" -c "Add :MinimumOSVersion string 17.0" \
  -c "Add :CFBundleSupportedPlatforms array" -c "Add :CFBundleSupportedPlatforms:0 string iPhoneSimulator" \
  -c "Add :UIDeviceFamily array" -c "Add :UIDeviceFamily:0 integer 1" \
  -c "Add :UILaunchScreen dict" -c "Add :UIApplicationSceneManifest dict" \
  -c "Add :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes bool false" "$plist" >/dev/null
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "$app"
