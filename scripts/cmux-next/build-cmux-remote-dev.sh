#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the UNSIGNED "cmux Remote (dev).app" (bundle id com.cmuxterm.remote.dev;
# docs/cmux-remote.md): the cmux-remote executable (Packages/macOS/CmuxRemote:
# host, Computer Use worker, Screen Sharing worker), the cmux Computer Use
# engine libcmux_computer_use.dylib (cmux-tui/crates/cmux-computer-use-ffi,
# MIT, built here with cargo for arm64, or CMUX_CU_DYLIB: a prebuilt copy),
# WebRTC (as a plain dylib), the SwiftPM resource bundles and the cmux Remote
# icon (Resources/CmuxRemote.icon, exported with Icon Composer's ictool). Every
# library sits in Contents/Frameworks as a plain dylib, never a nested
# .framework (a fleet cross build re-signs nested frameworks ad hoc). Run on a
# fleet Mac with Xcode and the cmux-tui Rust toolchain, never on a laptop.
# sign-cmux-remote-dev.sh signs it with Apple Development.
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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The Swift worker's copy of the C ABI header must be the crate's.
cmp -s "$repo_root/cmux-tui/crates/cmux-computer-use-ffi/include/cmux_computer_use.h" \
  "$package/Sources/CCmuxComputerUse/include/cmux_computer_use.h" ||
  { echo "error: Packages/macOS/CmuxRemote/Sources/CCmuxComputerUse/include/cmux_computer_use.h differs from the crate's header" >&2; exit 1; }
engine="${CMUX_CU_DYLIB:-}"
if [[ -z "$engine" ]]; then
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
  export CARGO_TARGET_DIR="${CMUX_CU_CARGO_TARGET_DIR:-$repo_root/.build/cmux-computer-use-target}"
  (cd "$repo_root/cmux-tui" && cargo build --release --locked -p cmux-computer-use-ffi --target aarch64-apple-darwin)
  engine="$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libcmux_computer_use_ffi.dylib"
fi
[[ -f "$engine" ]] || { echo "error: no libcmux_computer_use dylib at $engine" >&2; exit 1; }
lipo -info "$engine" | grep -q arm64 || { echo "error: $engine has no arm64 slice" >&2; exit 1; }

(cd "$package" && swift build -c release --arch arm64 --product "$EXECUTABLE")
bin_dir="$(cd "$package" && swift build -c release --arch arm64 --show-bin-path)"
CMUX_SWIFT_BIN_PATH="$bin_dir" "$SCRIPT_DIR/compile-string-catalogs.sh"

source_tree="$(cd "$repo_root" && { find Packages/macOS/CmuxRemote Packages/Shared/CmuxAgentCursor Packages/Shared/CmuxDeviceHub \
  Packages/Shared/CmuxVNCWebRTC Packages/Shared/CmuxVNC Resources/CmuxRemote.icon cmux-tui/crates/cmux-computer-use \
  cmux-tui/crates/cmux-computer-use-ffi -type f -not -path '*/.build/*' -not -path '*/.swiftpm/*'; } |
  LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "$f"; shasum -a 256 "$f" | awk '{print $1}'; done | shasum -a 256 | awk '{print $1}')"
engine_sha="$(shasum -a 256 "$engine" | awk '{print $1}')"
version="1.0.${source_tree:0:7}"
app="$work/$APP_NAME.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources/Licenses"
cp "$bin_dir/$EXECUTABLE" "$app/Contents/MacOS/$EXECUTABLE"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true
for bundle in "$bin_dir"/*.bundle; do cp -R "$bundle" "$app/Contents/Resources/"; done
cp "$engine" "$app/Contents/Frameworks/libcmux_computer_use.dylib"
chmod 755 "$app/Contents/Frameworks/libcmux_computer_use.dylib"
install_name_tool -id "@rpath/libcmux_computer_use.dylib" "$app/Contents/Frameworks/libcmux_computer_use.dylib"
# The WebRTC binary target SwiftPM linked (a dynamic framework), shipped as a plain dylib: a fleet
# cross build re-signs every nested .framework ad hoc, which would break this bundle's seal (and
# its Accessibility and Screen Recording grants); nested dylibs are left alone.
webrtc="$(find "$bin_dir" -maxdepth 2 -name WebRTC.framework -type d | head -1)"
[[ -n "$webrtc" ]] || { echo "error: WebRTC.framework not in $bin_dir" >&2; exit 1; }
cp "$webrtc/Versions/A/WebRTC" "$app/Contents/Frameworks/libWebRTC.dylib"
chmod 755 "$app/Contents/Frameworks/libWebRTC.dylib"
install_name_tool -id "@rpath/libWebRTC.dylib" "$app/Contents/Frameworks/libWebRTC.dylib"
install_name_tool -change "@rpath/WebRTC.framework/WebRTC" "@rpath/libWebRTC.dylib" "$app/Contents/MacOS/$EXECUTABLE"
otool -L "$app/Contents/MacOS/$EXECUTABLE" | grep -q "@rpath/libWebRTC.dylib" || { echo "error: cmux-remote does not load libWebRTC.dylib" >&2; exit 1; }
cp "$repo_root/cmux-tui/crates/cmux-computer-use-ffi/LICENSE" "$app/Contents/Resources/Licenses/LICENSE-cmux-computer-use"

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

It loads the cmux Computer Use engine (libcmux_computer_use.dylib,
cmux-tui/crates/cmux-computer-use and cmux-computer-use-ffi), MIT licensed:
see LICENSE-cmux-computer-use, and WebRTC (https://webrtc.org, BSD-3-Clause,
built by github.com/stasel/WebRTC).
TXT
/usr/bin/python3 -I - "$app/Contents/Info.plist" "$APP_NAME" "$BUNDLE_ID" "$EXECUTABLE" "$version" "$source_tree" "$engine_sha" <<'PY'
import plistlib, sys
path, name, bundle, exe, version, tree, engine = sys.argv[1:]
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
    "NSHumanReadableCopyright": "GPL-3.0-or-later. Includes cmux Computer Use (MIT) and WebRTC (BSD-3-Clause).",
    "CmuxRemoteSourceTree": tree,
    "CmuxComputerUseEngineSha256": engine,
}, open(path, "wb"))
PY
codesign --force --sign - "$app/Contents/Frameworks/libcmux_computer_use.dylib"
codesign --force --sign - "$app/Contents/Frameworks/libWebRTC.dylib"
codesign --force --sign - "$app"
mkdir -p "$out"
asset="cmux-remote-dev-unsigned-macos-arm64.zip"
ditto -c -k --keepParent --sequesterRsrc "$app" "$out/$asset"
cp "$app/Contents/Resources/AppIcon.icns" "$out/cmux-remote-icon.icns"
shasum -a 256 "$out/$asset" | tee "$out/$asset.sha256"
