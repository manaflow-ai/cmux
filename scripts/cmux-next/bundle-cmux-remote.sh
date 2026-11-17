#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds cmux-remote (Packages/macOS/CmuxRemote: the host, the Computer Use worker and the Screen
# Sharing worker; docs/cmux-remote.md) and places it inside a Computer Use helper app, so the
# supervisor and its workers hold the helper's one permission identity:
#
#   <helper>.app/Contents/MacOS/cmux-remote                 signed --identifier <the helper's id>
#   <helper>.app/Contents/Frameworks/libWebRTC.dylib        the WebRTC.framework SwiftPM linked, as a plain dylib
#   <helper>.app/Contents/Frameworks/libcua_driver_sdk.dylib the pinned Cua Driver SDK (cua-driver-sdk.pin.json),
#                                                           which the Computer Use worker dlopens from
#                                                           Bundle.main.privateFrameworksPath; arm64 only
#   <helper>.app/Contents/Resources/*.bundle                the SwiftPM resource bundles cmux-remote reads
#   <helper>.app/Contents/Resources/Licenses/               the SDK's licenses and cmux-remote.txt
#
# One script for both helpers:
#   Release, NIGHTLY, RC: "cmux Computer Use.app" (com.cmuxterm.cua), after build-cmux-cua.sh
#     --helper-app (scripts/ci/nightly-steps/app-assemble-computer-use-helper.sh). Release signing
#     signs cmux-remote with Developer ID, the hardened runtime and --identifier com.cmuxterm.cua,
#     and the dylibs, before it seals the helper (sign-cmux-bundle.sh, notarize-computer-use-helper.sh,
#     release-signer/sign-app.sh, rcodesign-sign-bundle.sh).
#   DEV: "cmux Computer Use (dev).app" (com.cmuxterm.cua.dev), from build-cua-helper-dev.sh with
#     --no-seal (it seals the app itself; sign-cua-helper-dev.sh signs it with the team).
#
# Here the nested code is signed ad hoc (cmux-remote with the helper's identifier), and without
# --no-seal the helper is re-sealed ad hoc with the stable requirement build-cmux-cua.sh gives it.
#
#   bundle-cmux-remote.sh --into HELPER.app --identifier ID [--archs "arm64 x86_64"] [--no-seal]
#
# --archs: the slices cmux-remote and libWebRTC.dylib carry (default arm64); one per
# `swift build --arch`, joined with lipo. The pinned SDK has only an arm64 slice: it is placed when
# arm64 is asked for and left out otherwise. A universal app carries it arm64-only (an Intel Mac
# then reports the Computer Use driver unavailable), and the thin x86_64 nightly variant drops it
# before thinning (scripts/cmux-next/drop-cua-sdk-without-arch.sh).
#
# CMUX_CUA_SDK_TARBALL=<path> uses a local SDK tarball instead of the cache, store or R2 (still checked
# against the pin's sha256); CMUX_CUA_SDK_PIN=<pin.json> checks it against another pin. The nightly
# reads the tarball from the cache its background fetch filled (app-fetch-chromium-engine.sh).
# Needs a Mac with Xcode and the Swift toolchain cmux builds with.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
usage="usage: bundle-cmux-remote.sh --into HELPER.app --identifier ID [--archs \"arm64 x86_64\"] [--no-seal]"
helper=""; identifier=""; archs="arm64"; seal=1
while (( $# )); do
  case "$1" in
    --into) helper="${2:?$usage}"; shift 2 ;;
    --identifier) identifier="${2:?$usage}"; shift 2 ;;
    --archs) archs="${2:?$usage}"; shift 2 ;;
    --no-seal) seal=0; shift ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
[[ -n "$helper" && -n "$identifier" ]] || { echo "$usage" >&2; exit 2; }
helper="${helper%/}"
[[ -d "$helper/Contents" && ! -L "$helper" ]] || { echo "error: no helper app at $helper" >&2; exit 1; }
read -r -a arch_list <<<"$archs"
(( ${#arch_list[@]} > 0 )) || { echo "error: --archs is empty" >&2; exit 2; }
for arch in "${arch_list[@]}"; do
  case "$arch" in arm64|x86_64) ;; *) echo "error: unsupported architecture '$arch'" >&2; exit 2 ;; esac
done
EXECUTABLE=cmux-remote
package="$repo_root/Packages/macOS/CmuxRemote"
codesign_tool="$repo_root/scripts/codesign-retry.sh"

# The pinned Cua Driver SDK: its dylib, its header (which the vendored ABI header must equal) and licenses.
sdk_pin="${CMUX_CUA_SDK_PIN:-$SCRIPT_DIR/cua-driver-sdk.pin.json}"
sdk_tar="$(CMUX_CUA_ASSET_FILE="${CMUX_CUA_SDK_TARBALL:-}" "$SCRIPT_DIR/ensure-cua-pinned-asset.sh" "$sdk_pin")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -xzf "$sdk_tar" -C "$work"
sdk="$work/cua-driver-sdk-macos-arm64"
[[ -f "$sdk/lib/libcua_driver_sdk.dylib" ]] || { echo "error: the SDK tarball has no dylib" >&2; exit 1; }
cmp -s "$sdk/include/cua_driver_abi.h" "$repo_root/Packages/macOS/CmuxComputerUseHelper/Sources/CCuaDriverABI/include/cua_driver_abi.h" ||
  { echo "error: the vendored cua_driver_abi.h differs from the pinned SDK header" >&2; exit 1; }

# One release build per slice; the resource bundles and WebRTC.framework come from the first.
slices=(); first_bin=""
for arch in "${arch_list[@]}"; do
  (cd "$package" && swift build -c release --arch "$arch" --product "$EXECUTABLE")
  bin_dir="$(cd "$package" && swift build -c release --arch "$arch" --show-bin-path)"
  [[ -n "$first_bin" ]] || first_bin="$bin_dir"
  slices+=("$bin_dir/$EXECUTABLE")
done
CMUX_SWIFT_BIN_PATH="$first_bin" "$SCRIPT_DIR/compile-string-catalogs.sh"
exe="$work/$EXECUTABLE"
if (( ${#slices[@]} == 1 )); then
  cp "${slices[0]}" "$exe"
else
  lipo -create "${slices[@]}" -output "$exe"
fi
chmod 755 "$exe"

# The WebRTC binary target SwiftPM linked (a dynamic framework), shipped as a plain dylib: a fleet
# cross build re-signs every nested .framework ad hoc, which would break the helper's seal (and
# its Accessibility and Screen Recording grants); nested dylibs are left alone. The xcframework's
# macOS slice is universal: the dylib keeps exactly the slices asked for.
webrtc="$(find "$first_bin" -maxdepth 2 -name WebRTC.framework -type d | head -1)"
[[ -n "$webrtc" ]] || { echo "error: WebRTC.framework not in $first_bin" >&2; exit 1; }
webrtc_dylib="$work/libWebRTC.dylib"
have="$(lipo -archs "$webrtc/Versions/A/WebRTC")"
for arch in "${arch_list[@]}"; do
  [[ " $have " == *" $arch "* ]] || { echo "error: WebRTC.framework has '$have', cmux-remote needs '$archs'" >&2; exit 1; }
done
if (( ${#arch_list[@]} == 1 )); then
  if [[ "$have" == "${arch_list[0]}" ]]; then
    cp "$webrtc/Versions/A/WebRTC" "$webrtc_dylib"
  else
    lipo "$webrtc/Versions/A/WebRTC" -thin "${arch_list[0]}" -output "$webrtc_dylib"
  fi
else
  extract=()
  for arch in "${arch_list[@]}"; do extract+=(-extract "$arch"); done
  lipo "$webrtc/Versions/A/WebRTC" "${extract[@]}" -output "$webrtc_dylib"
fi
chmod 755 "$webrtc_dylib"
install_name_tool -id "@rpath/libWebRTC.dylib" "$webrtc_dylib"
install_name_tool -change "@rpath/WebRTC.framework/WebRTC" "@rpath/libWebRTC.dylib" "$exe"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe" 2>/dev/null || true
otool -L "$exe" | grep -q "@rpath/libWebRTC.dylib" || { echo "error: cmux-remote does not load libWebRTC.dylib" >&2; exit 1; }
for arch in "${arch_list[@]}"; do
  lipo "$exe" -verify_arch "$arch" || { echo "error: cmux-remote has no $arch slice ($(lipo -archs "$exe"))" >&2; exit 1; }
done

# SwiftPM links the toolchain's back-deployment directory as an LC_RPATH
# (/Applications/Xcode_*.app/.../usr/lib/swift-6.2/macosx). The signed-app checks
# (verify-bundle-load-commands.sh) refuse a load path outside the app and the system, and on a Mac
# with that Xcode it would load toolchain code: nightly-next run 43864670865 failed on it. Remove
# every such rpath before signing, as build-cmux-cua.sh does. Only a Swift back-deployment library
# loaded through @rpath would need that directory; cmux-remote ships none, so naming one is an
# error here rather than a launch failure on macOS 14.
if otool -L "$exe" | awk '{print $1}' | grep -E '^@rpath/libswift'; then
  echo "error: cmux-remote loads a Swift back-deployment library through @rpath; raise its floor or ship it" >&2; exit 1
fi
dylibs=("$webrtc_dylib")
with_sdk=0
if [[ " $archs " == *" arm64 "* ]]; then
  with_sdk=1
  cp "$sdk/lib/libcua_driver_sdk.dylib" "$work/libcua_driver_sdk.dylib"
  dylibs+=("$work/libcua_driver_sdk.dylib")
fi
"$repo_root/scripts/strip-cmux-cua-rpaths.sh" "$exe" "${dylibs[@]}"
if otool -l "$exe" "${dylibs[@]}" | grep -A2 LC_RPATH | grep -E '^ +path /' | grep -v ' /usr/lib/swift '; then
  echo "error: an absolute rpath outside the system is left in cmux-remote" >&2; exit 1
fi

# Place it. Nothing of an earlier placement survives that this one would not write.
contents="$helper/Contents"
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources/Licenses"
cp "$exe" "$contents/MacOS/.$EXECUTABLE.tmp.$$"
mv -f "$contents/MacOS/.$EXECUTABLE.tmp.$$" "$contents/MacOS/$EXECUTABLE"
cp "$webrtc_dylib" "$contents/Frameworks/libWebRTC.dylib"
if (( with_sdk )); then
  cp "$work/libcua_driver_sdk.dylib" "$contents/Frameworks/libcua_driver_sdk.dylib"
else
  rm -f "$contents/Frameworks/libcua_driver_sdk.dylib"
  echo "note: no arm64 slice asked for: the pinned Cua Driver SDK (arm64 only) is left out; the Computer Use worker reports it unavailable"
fi
for bundle in "$first_bin"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  rm -rf "$contents/Resources/${bundle##*/}"
  cp -R "$bundle" "$contents/Resources/"
done
cp "$sdk/licenses/"* "$contents/Resources/Licenses/"
source_tree="$(cd "$repo_root" && { find Packages/macOS/CmuxRemote Packages/macOS/CmuxComputerUseHelper Packages/Shared/CmuxDeviceHub \
  Packages/Shared/CmuxVNCWebRTC Packages/Shared/CmuxVNC -type f -not -path '*/.build/*' -not -path '*/.swiftpm/*'; } |
  LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "$f"; shasum -a 256 "$f" | awk '{print $1}'; done | shasum -a 256 | awk '{print $1}')"
cat > "$contents/Resources/Licenses/cmux-remote.txt" <<TXT
cmux-remote (Contents/MacOS/cmux-remote: the host, the Computer Use worker and the
Screen Sharing worker) is free software: its code (https://github.com/manaflow-ai/cmux,
Packages/macOS/CmuxRemote and the packages it uses, source sha256 $source_tree)
is licensed under the GNU General Public License, version 3 or later.

It loads Cua Driver (Contents/Frameworks/libcua_driver_sdk.dylib, https://github.com/trycua/cua),
MIT licensed: see LICENSE-cua* and THIRD_PARTY_NOTICES* here, and WebRTC
(Contents/Frameworks/libWebRTC.dylib, https://webrtc.org, BSD-3-Clause, built by
github.com/stasel/WebRTC).
TXT

# Nested code is signed before the bundle that seals it: the dylibs, then cmux-remote with the
# helper's identifier, so a macOS that checks the process by its own signature finds the
# helper's permission row.
for dylib in "$contents/Frameworks/libWebRTC.dylib" "$contents/Frameworks/libcua_driver_sdk.dylib"; do
  [[ -f "$dylib" ]] || continue
  "$codesign_tool" --force --sign - --timestamp=none "$dylib"
done
"$codesign_tool" --force --sign - --timestamp=none --identifier "$identifier" "$contents/MacOS/$EXECUTABLE"
if (( seal )); then
  "$codesign_tool" --force --sign - --timestamp=none --identifier "$identifier" \
    --requirements "=designated => identifier \"$identifier\"" "$helper"
fi
echo "bundled $EXECUTABLE ($(lipo -archs "$contents/MacOS/$EXECUTABLE")) into ${helper##*/} ($identifier)$( (( with_sdk )) || echo ', without the Cua Driver SDK')"
