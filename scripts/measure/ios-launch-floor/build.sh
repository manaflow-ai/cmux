#!/usr/bin/env bash
# Builds the launch floor app (FloorApp.swift) for the simulator: one swiftc call, no Xcode project.
#   build.sh OUT_DIR                         -> OUT_DIR/CmuxLaunchFloor.app (nothing to load: the simulator's own cost)
#   build.sh OUT_DIR --webrtc FW             -> CmuxLaunchFloorWebRTC.app: cmux's WebRTC.framework embedded and
#                                               loaded at launch (-needed_framework keeps it with no symbol used)
#   build.sh OUT_DIR --pad BYTES             -> CmuxLaunchFloorPad.app: BYTES of incompressible __TEXT,__cmuxpad,
#                                               never touched: what executable size alone costs before main
#   build.sh OUT_DIR --force-load LIB.a      -> CmuxLaunchFloorRust.app: the whole static library (cmux's Rust FFI)
#                                               force-loaded, so its code, data and fixups are in the floor's image
# Prints the .app path as its last line.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?usage: build.sh OUT_DIR [--webrtc FW | --pad BYTES | --force-load LIB.a]}"
shift
name=CmuxLaunchFloor
bundle_id=dev.cmux.launchfloor
link=()
webrtc=""
case "${1:-}" in
  "") ;;
  --webrtc)
    webrtc="${2:?--webrtc FW}"
    [[ -d "$webrtc" ]] || { echo "build.sh: no framework at $webrtc" >&2; exit 2; }
    name=CmuxLaunchFloorWebRTC; bundle_id=dev.cmux.launchfloor.webrtc
    link=(-F "$(dirname "$webrtc")" -Xlinker -needed_framework -Xlinker WebRTC
          -Xlinker -rpath -Xlinker @executable_path/Frameworks) ;;
  --pad)
    bytes="${2:?--pad BYTES}"
    name=CmuxLaunchFloorPad; bundle_id=dev.cmux.launchfloor.pad
    mkdir -p "$out"
    head -c "$bytes" /dev/urandom >"$out/pad.bin"
    link=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __cmuxpad -Xlinker "$out/pad.bin") ;;
  --force-load)
    lib="${2:?--force-load LIB.a}"
    [[ -f "$lib" ]] || { echo "build.sh: no library at $lib" >&2; exit 2; }
    name=CmuxLaunchFloorRust; bundle_id=dev.cmux.launchfloor.rust
    link=(-Xlinker -force_load -Xlinker "$lib" -lc++ -lz -lresolv -liconv
          -framework Security -framework SystemConfiguration -framework CFNetwork -framework Network
          -framework CoreFoundation -framework Foundation) ;;
  *) echo "build.sh: unknown argument $1" >&2; exit 2 ;;
esac
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
