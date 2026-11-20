#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the UNSIGNED "cmux Computer Use (dev).app" (bundle id com.cmuxterm.cua.dev;
# docs/cmux-remote.md): the cmux-remote executable (Packages/macOS/CmuxRemote:
# host, Computer Use worker, Screen Sharing worker), the cmux Computer Use
# engine libcmux_computer_use.dylib (cmux-tui/crates/cmux-computer-use-ffi,
# MIT, built here with cargo for each architecture, or CMUX_CU_DYLIB: a prebuilt copy),
# WebRTC (as a plain dylib), the SwiftPM resource bundles and the cmux Remote
# icon (Resources/CmuxRemote.icon, exported with Icon Composer's ictool). Every
# library sits in Contents/Frameworks as a plain dylib, never a nested
# .framework (a fleet cross build re-signs nested frameworks ad hoc). Run on a
# fleet Mac with Xcode and the cmux-tui Rust toolchain, never on a laptop.
# sign-cmux-remote-dev.sh signs it with Apple Development.
#
#   build-cmux-remote-dev.sh [--out DIR]            arm64 DEV zip for the pin signer
#   build-cmux-remote-dev.sh --release --archs "arm64 x86_64" --out DIR
#     writes DIR/cmux Computer Use.app for the release signer. CMUX_NEXT_SCREEN_HELPER_BIN
#     can supply the cmux-rd binary already built for the app.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
out="${NX_ARTIFACTS:-$PWD/out}"
release=0
arch_names=arm64
while (( $# )); do
  case "$1" in
    --out) out="${2:?}"; shift 2 ;;
    --release) release=1; shift ;;
    --archs) arch_names="${2:?}"; shift 2 ;;
    *) echo "usage: build-cmux-remote-dev.sh [--out DIR] [--release --archs 'arm64 x86_64']" >&2; exit 2 ;;
  esac
done
read -r -a archs <<< "$arch_names"
case "${archs[*]}" in
  arm64|x86_64|"arm64 x86_64"|"x86_64 arm64") ;;
  *) echo "error: unsupported helper architectures: $arch_names" >&2; exit 2 ;;
esac
APP_NAME="cmux Computer Use (dev)"
BUNDLE_ID="com.cmuxterm.cua.dev"
if (( release )); then
  APP_NAME="cmux Computer Use"
  BUNDLE_ID="com.cmuxterm.cua"
elif [[ "${archs[*]}" != arm64 ]]; then
  echo "error: the pinned DEV archive requires arm64" >&2
  exit 2
fi
EXECUTABLE="cmux-remote"
package="$repo_root/Packages/macOS/CmuxRemote"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The Swift worker's copy of the C ABI header must be the crate's.
cmp -s "$repo_root/cmux-tui/crates/cmux-computer-use-ffi/include/cmux_computer_use.h" \
  "$package/Sources/CCmuxComputerUse/include/cmux_computer_use.h" ||
  { echo "error: Packages/macOS/CmuxRemote/Sources/CCmuxComputerUse/include/cmux_computer_use.h differs from the crate's header" >&2; exit 1; }
# Keep precisely the requested slices, including when a prebuilt WebRTC or worker is universal.
thin_slice() {
  local source="$1" arch="$2" dest="$3"
  lipo "$source" -verify_arch "$arch" || { echo "error: $source lacks $arch" >&2; return 1; }
  if [[ "$(lipo -archs "$source")" == "$arch" ]]; then
    cp "$source" "$dest"
  else
    lipo "$source" -thin "$arch" -output "$dest"
  fi
}
assemble_slices() {
  local dest="$1"
  shift
  if [[ $# == 1 ]]; then cp "$1" "$dest"; else lipo -create "$@" -output "$dest"; fi
}

screen="${CMUX_NEXT_SCREEN_HELPER_BIN:-}"
if [[ -z "$screen" ]]; then
  screen="$work/cmux-screen-sharing"
  CMUX_NEXT_SCREEN_HELPER_ARCHS="${archs[*]}" "$SCRIPT_DIR/build-screen-sharing-helper.sh" --output "$screen"
fi
[[ -x "$screen" ]] || { echo "error: missing Screen Sharing worker: $screen" >&2; exit 1; }

engines=(); hosts=(); screens=(); webrtcs=()
first_bin=""
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export CARGO_TARGET_DIR="${CMUX_CU_CARGO_TARGET_DIR:-$repo_root/.build/cmux-computer-use-target}"
# shellcheck source=../lib/rust-targets.sh
source "$repo_root/scripts/lib/rust-targets.sh"
for arch in "${archs[@]}"; do
  engine="${CMUX_CU_DYLIB:-}"
  if [[ -z "$engine" ]]; then
    case "$arch" in arm64) target=aarch64-apple-darwin ;; x86_64) target=x86_64-apple-darwin ;; esac
    (cd "$repo_root/cmux-tui" && ensure_rust_targets "$target" && cargo build --release --locked -p cmux-computer-use-ffi --target "$target")
    engine="$CARGO_TARGET_DIR/$target/release/libcmux_computer_use_ffi.dylib"
  fi
  (cd "$package" && swift build -c release --arch "$arch" --product "$EXECUTABLE")
  bin_dir="$(cd "$package" && swift build -c release --arch "$arch" --show-bin-path)"
  webrtc=""
  for framework in "$bin_dir"/WebRTC.framework "$bin_dir"/*/WebRTC.framework; do
    if [[ -d "$framework" ]]; then webrtc="$framework"; break; fi
  done
  [[ -n "$webrtc" ]] || { echo "error: WebRTC.framework missing for $arch in $bin_dir" >&2; exit 1; }
  thin_slice "$engine" "$arch" "$work/engine-$arch"
  thin_slice "$bin_dir/$EXECUTABLE" "$arch" "$work/host-$arch"
  thin_slice "$screen" "$arch" "$work/screen-$arch"
  thin_slice "$webrtc/Versions/A/WebRTC" "$arch" "$work/webrtc-$arch"
  engines+=("$work/engine-$arch"); hosts+=("$work/host-$arch")
  screens+=("$work/screen-$arch"); webrtcs+=("$work/webrtc-$arch")
  if [[ -z "$first_bin" ]]; then first_bin="$bin_dir"; fi
done
CMUX_SWIFT_BIN_PATH="$first_bin" "$SCRIPT_DIR/compile-string-catalogs.sh"

source_tree="$(cd "$repo_root" && { find Packages/macOS/CmuxRemote Packages/Shared/CmuxAgentCursor Packages/Shared/CmuxDeviceHub \
  Packages/Shared/CmuxVNCWebRTC Packages/Shared/CmuxVNC Resources/CmuxRemote.icon cmux-tui/crates/cmux-computer-use \
  cmux-tui/crates/cmux-computer-use-ffi -type f -not -path '*/.build/*' -not -path '*/.swiftpm/*'; } |
  LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "$f"; shasum -a 256 "$f" | awk '{print $1}'; done | shasum -a 256 | awk '{print $1}')"
# CFBundleVersion is numeric; the full source and engine digests are recorded separately.
version="${CURRENT_PROJECT_VERSION:-1}"
app="$work/$APP_NAME.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources/Licenses"
assemble_slices "$app/Contents/MacOS/$EXECUTABLE" "${hosts[@]}"
assemble_slices "$app/Contents/MacOS/cmux-screen-sharing" "${screens[@]}"
chmod 755 "$app/Contents/MacOS/"*
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true
for bundle in "$first_bin"/*.bundle; do cp -R "$bundle" "$app/Contents/Resources/"; done
assemble_slices "$app/Contents/Frameworks/libcmux_computer_use.dylib" "${engines[@]}"
engine_sha="$(shasum -a 256 "$app/Contents/Frameworks/libcmux_computer_use.dylib" | awk '{print $1}')"
chmod 755 "$app/Contents/Frameworks/libcmux_computer_use.dylib"
install_name_tool -id "@rpath/libcmux_computer_use.dylib" "$app/Contents/Frameworks/libcmux_computer_use.dylib"
# The WebRTC binary target SwiftPM linked (a dynamic framework), shipped as a plain dylib: a fleet
# cross build re-signs every nested .framework ad hoc, which would break this bundle's seal (and
# its Accessibility and Screen Recording grants); nested dylibs are left alone.
assemble_slices "$app/Contents/Frameworks/libWebRTC.dylib" "${webrtcs[@]}"
chmod 755 "$app/Contents/Frameworks/libWebRTC.dylib"
install_name_tool -id "@rpath/libWebRTC.dylib" "$app/Contents/Frameworks/libWebRTC.dylib"
install_name_tool -change "@rpath/WebRTC.framework/WebRTC" "@rpath/libWebRTC.dylib" "$app/Contents/MacOS/$EXECUTABLE"
otool -L "$app/Contents/MacOS/$EXECUTABLE" | grep -q "@rpath/libWebRTC.dylib" || { echo "error: cmux-remote does not load libWebRTC.dylib" >&2; exit 1; }
# SwiftPM links the toolchain's back-deployment directory as an LC_RPATH
# (/Applications/Xcode_*.app/.../usr/lib/swift-6.2/macosx). The signed-app checks
# (verify-bundle-load-commands.sh) refuse a load path outside the app and the system,
# and on a Mac with that Xcode it would load toolchain code: nightly-next run
# 43864670865 failed on it. Remove every such rpath before signing
# (strip-toolchain-rpaths.sh). Only a Swift back-deployment library loaded through @rpath would need that
# directory; the helper ships none (the signer takes exactly the two dylibs), so
# naming one is an error here rather than a launch failure on macOS 14.
if otool -L "$app/Contents/MacOS/$EXECUTABLE" | awk '{print $1}' | grep -E '^@rpath/libswift'; then
  echo "error: cmux-remote loads a Swift back-deployment library through @rpath; raise its floor or ship it" >&2; exit 1
fi
"$SCRIPT_DIR/strip-toolchain-rpaths.sh" "$app/Contents/MacOS/$EXECUTABLE" \
  "$app/Contents/Frameworks/libWebRTC.dylib" "$app/Contents/Frameworks/libcmux_computer_use.dylib"
if otool -l "$app/Contents/MacOS/$EXECUTABLE" "$app"/Contents/Frameworks/*.dylib | grep -A2 LC_RPATH | grep -E '^ +path /' | grep -v ' /usr/lib/swift '; then
  echo "error: an absolute rpath outside the system is left in cmux Remote" >&2; exit 1
fi
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
$APP_NAME is free software: its code (https://github.com/manaflow-ai/cmux,
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
codesign --force --sign - --identifier "$BUNDLE_ID" "$app/Contents/MacOS/cmux-screen-sharing"
codesign --force --sign - "$app"
mkdir -p "$out"
if (( release )); then
  [[ ! -e "$out/$APP_NAME.app" ]] || { echo "error: $out/$APP_NAME.app already exists" >&2; exit 1; }
  ditto "$app" "$out/$APP_NAME.app"
  exit 0
fi
asset="cmux-remote-dev-unsigned-macos-arm64.zip"
ditto -c -k --keepParent --sequesterRsrc "$app" "$out/$asset"
cp "$app/Contents/Resources/AppIcon.icns" "$out/cmux-remote-icon.icns"
shasum -a 256 "$out/$asset" | tee "$out/$asset.sha256"
