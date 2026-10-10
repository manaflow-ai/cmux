#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the UNSIGNED "cmux Computer Use (dev).app" (bundle id
# com.cmuxterm.cua.dev): the Swift helper (Packages/macOS/CmuxComputerUseHelper)
# plus the pinned upstream libcua_driver_sdk.dylib (cua-driver-sdk.pin.json).
# Run on cmux-lawrence-2 (nx-remote) or a fleet Mac, never on a laptop.
# sign-cua-helper-dev.sh signs it with Apple Development and publishes it.
#
#   build-cua-helper-dev.sh [--out DIR]   (default $NX_ARTIFACTS or ./out)
#
# CMUX_CUA_SDK_TARBALL=<path> uses a local SDK tarball instead of R2 (it is
# still checked against the pin sha256).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
out="${NX_ARTIFACTS:-$PWD/out}"
while (( $# )); do
  case "$1" in
    --out) out="${2:?}"; shift 2 ;;
    *) echo "usage: build-cua-helper-dev.sh [--out DIR]" >&2; exit 2 ;;
  esac
done
APP_NAME="cmux Computer Use (dev)"
BUNDLE_ID="com.cmuxterm.cua.dev"
EXECUTABLE="cmux-cua-helper"
package="$repo_root/Packages/macOS/CmuxComputerUseHelper"

sdk_tar="$(CMUX_CUA_ASSET_FILE="${CMUX_CUA_SDK_TARBALL:-}" "$SCRIPT_DIR/ensure-cua-pinned-asset.sh" "$SCRIPT_DIR/cua-driver-sdk.pin.json")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -xzf "$sdk_tar" -C "$work"
sdk="$work/cua-driver-sdk-macos-arm64"
[[ -f "$sdk/lib/libcua_driver_sdk.dylib" ]] || { echo "error: the SDK tarball has no dylib" >&2; exit 1; }
# The vendored header must be the pinned header.
cmp -s "$sdk/include/cua_driver_abi.h" "$package/Sources/CCuaDriverABI/include/cua_driver_abi.h" ||
  { echo "error: Sources/CCuaDriverABI/include/cua_driver_abi.h differs from the pinned SDK header" >&2; exit 1; }

(cd "$package" && swift build -c release --arch arm64 --product "$EXECUTABLE")
bin="$(cd "$package" && swift build -c release --arch arm64 --show-bin-path)/$EXECUTABLE"

# Content hash of the helper sources (path + bytes of every file except
# .build), so the provenance holds for a synced tree with no commit too.
source_tree="$(cd "$package" && find . -type f -not -path './.build/*' -not -path './.swiftpm/*' | LC_ALL=C sort |
  while IFS= read -r f; do printf '%s\n' "$f"; shasum -a 256 "$f" | awk '{print $1}'; done | shasum -a 256 | awk '{print $1}')"
sdk_sha="$(shasum -a 256 "$sdk_tar" | awk '{print $1}')"
version="1.0.${source_tree:0:7}"
app="$work/$APP_NAME.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources/Licenses"
cp "$bin" "$app/Contents/MacOS/$EXECUTABLE"
cp "$sdk/lib/libcua_driver_sdk.dylib" "$app/Contents/Frameworks/"
cp "$sdk/licenses/"* "$app/Contents/Resources/Licenses/"
[[ -f "$repo_root/Resources/ComputerUseHelperIcon.icns" ]] && cp "$repo_root/Resources/ComputerUseHelperIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Resources/Licenses/README.txt" <<TXT
cmux Computer Use (dev) is free software: the helper code (Swift, from
https://github.com/manaflow-ai/cmux, Packages/macOS/CmuxComputerUseHelper,
source sha256 $source_tree) is licensed under the GNU General Public License,
version 3 or later.

It loads Cua Driver (libcua_driver_sdk.dylib, https://github.com/trycua/cua,
$(/usr/bin/python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("tag", d["upstream_tag"], "commit", d["upstream_commit"])' "$sdk/build-info.json")),
MIT licensed: see LICENSE-cua* and THIRD_PARTY_NOTICES*. Its Rust dependencies
are listed with their licenses in cargo-dependencies.txt.

Source offer for MPL-2.0 components: the uniffi crates (uniffi 0.31.0 and
its sub-crates, https://github.com/mozilla/uniffi-rs) are licensed under
the Mozilla Public License 2.0. Their source code is available at
https://github.com/mozilla/uniffi-rs/tree/v0.31.0 and from crates.io, and
Manaflow, Inc. provides it on request at the address on https://cmux.com.

The Cua perception extension (AGPL-3.0-only) is not included.
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
    "LSMinimumSystemVersion": "15.0",
    "LSUIElement": True,
    "NSHumanReadableCopyright": "GPL-3.0-or-later. Includes Cua Driver (MIT).",
    "CmuxHelperSourceTree": tree,
    "CmuxCuaDriverSDKSha256": sdk,
}, open(path, "wb"))
PY
# Ad-hoc signatures only so the bundle is valid; sign-cua-helper-dev.sh
# replaces them with Apple Development.
codesign --force --sign - "$app/Contents/Frameworks/libcua_driver_sdk.dylib"
codesign --force --sign - "$app"
mkdir -p "$out"
asset="cmux-computer-use-dev-unsigned-macos-arm64.zip"
ditto -c -k --keepParent --sequesterRsrc "$app" "$out/$asset"
shasum -a 256 "$out/$asset" | tee "$out/$asset.sha256"
