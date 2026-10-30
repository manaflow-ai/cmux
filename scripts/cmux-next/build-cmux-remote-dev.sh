#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the UNSIGNED "cmux Remote (dev).app" (bundle id com.cmuxterm.remote.dev;
# docs/cmux-remote.md): the cmux-remote executable (Packages/macOS/CmuxRemote:
# host, Computer Use worker, Screen Sharing worker), the pinned upstream
# libcua_driver_sdk.dylib (cua-driver-sdk.pin.json), WebRTC.framework, the
# SwiftPM resource bundles and the cmux Remote icon (Resources/CmuxRemote.icon,
# exported with Icon Composer's ictool). Run on a fleet Mac with Xcode, never
# on a laptop. sign-cmux-remote-dev.sh signs it with Apple Development.
#
#   build-cmux-remote-dev.sh [--out DIR]   (default $NX_ARTIFACTS or ./out)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
out="${NX_ARTIFACTS:-$PWD/out}"
while (( $# )); do
  case "$1" in
    --out) out="${2:?}"; shift 2 ;;
    *) echo "usage: build-cmux-remote-dev.sh [--out DIR]" >&2; exit 2 ;;
  esac
done
APP_NAME="cmux Remote (dev)"
BUNDLE_ID="com.cmuxterm.remote.dev"
EXECUTABLE="cmux-remote"
package="$repo_root/Packages/macOS/CmuxRemote"

sdk_tar="$(CMUX_CUA_ASSET_FILE="${CMUX_CUA_SDK_TARBALL:-}" "$SCRIPT_DIR/ensure-cua-pinned-asset.sh" "$SCRIPT_DIR/cua-driver-sdk.pin.json")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -xzf "$sdk_tar" -C "$work"
sdk="$work/cua-driver-sdk-macos-arm64"
[[ -f "$sdk/lib/libcua_driver_sdk.dylib" ]] || { echo "error: the SDK tarball has no dylib" >&2; exit 1; }
cmp -s "$sdk/include/cua_driver_abi.h" "$repo_root/Packages/macOS/CmuxComputerUseHelper/Sources/CCuaDriverABI/include/cua_driver_abi.h" ||
  { echo "error: the vendored cua_driver_abi.h differs from the pinned SDK header" >&2; exit 1; }

(cd "$package" && swift build -c release --arch arm64 --product "$EXECUTABLE")
bin_dir="$(cd "$package" && swift build -c release --arch arm64 --show-bin-path)"
CMUX_SWIFT_BIN_PATH="$bin_dir" "$SCRIPT_DIR/compile-string-catalogs.sh"

source_tree="$(cd "$repo_root" && { find Packages/macOS/CmuxRemote Packages/macOS/CmuxComputerUseHelper Packages/Shared/CmuxDeviceHub \
  Packages/Shared/CmuxVNCWebRTC Packages/Shared/CmuxVNC Resources/CmuxRemote.icon -type f -not -path '*/.build/*' -not -path '*/.swiftpm/*'; } |
  LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "$f"; shasum -a 256 "$f" | awk '{print $1}'; done | shasum -a 256 | awk '{print $1}')"
sdk_sha="$(shasum -a 256 "$sdk_tar" | awk '{print $1}')"
version="1.0.${source_tree:0:7}"
app="$work/$APP_NAME.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources/Licenses"
cp "$bin_dir/$EXECUTABLE" "$app/Contents/MacOS/$EXECUTABLE"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true
for bundle in "$bin_dir"/*.bundle; do cp -R "$bundle" "$app/Contents/Resources/"; done
cp "$sdk/lib/libcua_driver_sdk.dylib" "$app/Contents/Frameworks/"
# The WebRTC binary target SwiftPM linked (a dynamic framework).
webrtc="$(find "$bin_dir" -maxdepth 2 -name WebRTC.framework -type d | head -1)"
[[ -n "$webrtc" ]] || { echo "error: WebRTC.framework not in $bin_dir" >&2; exit 1; }
cp -R "$webrtc" "$app/Contents/Frameworks/"
cp "$sdk/licenses/"* "$app/Contents/Resources/Licenses/"

# The icon: Icon Composer document -> iconset -> icns.
ictool="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
  points="${spec%%:*}"; scale="${spec##*:}"
  suffix=""; [[ $scale == 2 ]] && suffix="@2x"
  name="icon_${points}x${points}${suffix}.png"
  "$ictool" "$repo_root/Resources/CmuxRemote.icon" --export-image --output-file "$iconset/$name" \
    --platform macOS --rendition Default --width "$points" --height "$points" --scale "$scale" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Resources/Licenses/README.txt" <<TXT
cmux Remote (dev) is free software: its code (https://github.com/manaflow-ai/cmux,
Packages/macOS/CmuxRemote and the packages it uses, source sha256 $source_tree)
is licensed under the GNU General Public License, version 3 or later.

It loads Cua Driver (libcua_driver_sdk.dylib, https://github.com/trycua/cua),
MIT licensed: see LICENSE-cua* and THIRD_PARTY_NOTICES*, and WebRTC
(https://webrtc.org, BSD-3-Clause, built by github.com/stasel/WebRTC).
TXT
/usr/bin/python3 -I - "$app/Contents/Info.plist" "$APP_NAME" "$BUNDLE_ID" "$EXECUTABLE" "$version" "$source_tree" "$sdk_sha" <<'PY'
import plistlib, sys
path, name, bundle, exe, version, tree, sdk = sys.argv[1:]
plistlib.dump({
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": name,
    "CFBundleName": name,
    "CFBundleIdentifier": bundle,
    "CFBundleExecutable": exe,
    "CFBundleIconFile": "AppIcon",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": version,
    "LSMinimumSystemVersion": "14.0",
    "LSUIElement": True,
    "NSHumanReadableCopyright": "GPL-3.0-or-later. Includes Cua Driver (MIT) and WebRTC (BSD-3-Clause).",
    "CmuxRemoteSourceTree": tree,
    "CmuxCuaDriverSDKSha256": sdk,
}, open(path, "wb"))
PY
codesign --force --sign - "$app/Contents/Frameworks/libcua_driver_sdk.dylib"
codesign --force --sign - "$app/Contents/Frameworks/WebRTC.framework"
codesign --force --sign - "$app"
mkdir -p "$out"
asset="cmux-remote-dev-unsigned-macos-arm64.zip"
ditto -c -k --keepParent --sequesterRsrc "$app" "$out/$asset"
cp "$app/Contents/Resources/AppIcon.icns" "$out/cmux-remote-icon.icns"
shasum -a 256 "$out/$asset" | tee "$out/$asset.sha256"
