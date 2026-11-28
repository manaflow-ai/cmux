#!/usr/bin/env bash
# Builds the launch floor app (FloorApp.swift) for the simulator: one swiftc call, no Xcode project.
#   build.sh OUT_DIR                         -> OUT_DIR/CmuxLaunchFloor.app (nothing to load: the simulator's own cost)
# Options add one thing the app has to the floor (they combine; each adds a suffix to the name and bundle id):
#   --webrtc FW          cmux's WebRTC.framework embedded and loaded at launch (-needed_framework, no symbol used)
#   --pad BYTES          BYTES of incompressible __TEXT,__cmuxpad, never touched: executable size alone
#   --force-load LIB.a   the whole static library (cmux's Rust FFI) force-loaded: its code, data and fixups
#   --needed-from FILE   every library in FILE (one install name per line, as `otool -L` prints them) whose stub
#                        is in the SDK, loaded at launch with no symbol used: the app's system dylibs and frameworks
#   --ent PLIST          signed with PLIST's entitlements, also in __TEXT,__entitlements as Xcode does for the
#                        simulator: the app's app groups, keychain groups and capabilities at spawn
# Prints the .app path as its last line.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?usage: build.sh OUT_DIR [--webrtc FW] [--pad BYTES] [--force-load LIB.a] [--needed-from FILE] [--ent PLIST]}"
shift
name=CmuxLaunchFloor
bundle_id=dev.cmux.launchfloor
link=()
webrtc=""
ent=""
mkdir -p "$out"
sdk="$(xcrun -sdk iphonesimulator --show-sdk-path)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --webrtc)
      webrtc="${2:?--webrtc FW}"
      [[ -d "$webrtc" ]] || { echo "build.sh: no framework at $webrtc" >&2; exit 2; }
      name+=WebRTC; bundle_id+=.webrtc
      link+=(-F "$(dirname "$webrtc")" -Xlinker -needed_framework -Xlinker WebRTC
             -Xlinker -rpath -Xlinker @executable_path/Frameworks) ;;
    --pad)
      name+=Pad; bundle_id+=.pad
      head -c "${2:?--pad BYTES}" /dev/urandom >"$out/pad.bin"
      link+=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __cmuxpad -Xlinker "$out/pad.bin") ;;
    --force-load)
      lib="${2:?--force-load LIB.a}"
      [[ -f "$lib" ]] || { echo "build.sh: no library at $lib" >&2; exit 2; }
      name+=Rust; bundle_id+=.rust
      link+=(-Xlinker -force_load -Xlinker "$lib" -lc++ -lz -lresolv -liconv
             -framework Security -framework SystemConfiguration -framework CFNetwork -framework Network
             -framework CoreFoundation -framework Foundation) ;;
    --needed-from)
      list="${2:?--needed-from FILE}"
      name+=Dylibs; bundle_id+=.dylibs
      : >"$out/needed-used.txt"; : >"$out/needed-skipped.txt"
      toolchain_swift="$(dirname "$(xcrun -f swiftc)")/../lib/swift/iphonesimulator"
      while read -r p; do
        [[ -n "$p" ]] || continue
        stub=""
        case "$p" in
          @rpath/libswift*.dylib)
            b="${p#@rpath/}"
            for d in "$sdk/usr/lib/swift" "$toolchain_swift"; do
              [[ -f "$d/${b%.dylib}.tbd" ]] && { stub="$d/${b%.dylib}.tbd"; break; }
              [[ -f "$d/$b" ]] && { stub="$d/$b"; break; }
            done ;;
          @*) ;;  # embedded frameworks: the --webrtc arm measures those
          *) for c in "$sdk${p%.dylib}.tbd" "$sdk$p.tbd" "$sdk$p"; do [[ -f "$c" ]] && { stub="$c"; break; }; done ;;
        esac
        if [[ -n "$stub" ]]; then
          link+=(-Xlinker -needed_library -Xlinker "$stub"); echo "$p" >>"$out/needed-used.txt"
        else
          echo "$p" >>"$out/needed-skipped.txt"
        fi
      done <"$list"
      echo "build.sh: --needed-from: $(wc -l <"$out/needed-used.txt" | tr -d ' ') linked, $(wc -l <"$out/needed-skipped.txt" | tr -d ' ') without an SDK stub" >&2 ;;
    --ent)
      ent="${2:?--ent PLIST}"
      [[ -f "$ent" ]] || { echo "build.sh: no entitlements at $ent" >&2; exit 2; }
      name+=Ent; bundle_id+=.ent
      link+=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$ent") ;;
    *) echo "build.sh: unknown argument $1" >&2; exit 2 ;;
  esac
  shift 2
done
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
if [[ -n "$ent" ]]; then
  codesign --force --sign - --entitlements "$ent" "$app" >/dev/null 2>&1 || true
else
  codesign --force --sign - "$app" >/dev/null 2>&1 || true
fi
echo "$app"
