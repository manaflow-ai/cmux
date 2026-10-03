#!/usr/bin/env bash
# Xcode "Bundle server helper" phase of the cmux-next target
# (plans/cmux-next/server.md 9.4): the cmux server's privileged helper.
#
#   Contents/Resources/libexec/cmux-server-helper           the helper (root, launchd)
#   Contents/Library/LaunchDaemons/com.cmux.server.helper.plist
#
# The app registers the plist with SMAppService.daemon; the user approves it once
# in System Settings > Login Items. The plist names a per-build label
# (`<bundle id>.server-helper`) and passes `--app <bundle id>`, so each tagged
# build has its own helper and the helper serves only the app that carries it.
#
# The helper is compiled here with swiftc from
# Packages/macOS/CmuxNext/Sources/CmuxNextServerHelper (a module with no package
# dependencies) and Sources/CmuxNextServerHelperDaemon/main.swift, one slice per
# arch in $ARCHS. Resolving the whole CmuxNext package for one small executable
# would fetch every remote dependency inside the phase.
#
# Stable builds (bundle id com.cmuxterm.app) do not carry the helper: the server
# actions are DEV and NIGHTLY only. scripts/sign-cmux-bundle.sh signs
# Contents/Resources/libexec/* for Developer ID; here the helper gets the build's
# identity and the identifier cmux-server-helper (the file name, as there).
#
# Usage outside Xcode: TARGET_BUILD_DIR=<dir containing the .app> WRAPPER_NAME=<x.app>
#   PRODUCT_BUNDLE_IDENTIFIER=<id> scripts/cmux-next/bundle-server-helper.sh
set -euo pipefail

bundle_id="${PRODUCT_BUNDLE_IDENTIFIER:?}"
app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
contents="$app/Contents"
helper="$contents/Resources/libexec/cmux-server-helper"
plist="$contents/Library/LaunchDaemons/com.cmux.server.helper.plist"

if [[ "$bundle_id" == "com.cmuxterm.app" ]]; then
  rm -f "$helper" "$plist"
  echo "bundle-server-helper: stable build, no server helper"
  exit 0
fi
if [[ ! "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
  echo "error: bundle-server-helper: bundle id '$bundle_id' is not a plain reverse-DNS name" >&2
  exit 1
fi
label="$bundle_id.server-helper"

root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
sources="$root/Packages/macOS/CmuxNext/Sources"
work="${TARGET_TEMP_DIR:-$(mktemp -d)}/server-helper"
min_macos="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
optimize="-O"
[[ "${CONFIGURATION:-Debug}" == "Debug" ]] && optimize="-Onone"
swift_flags=(
  -swift-version 6
  -enable-upcoming-feature NonisolatedNonsendingByDefault
  -enable-upcoming-feature InferIsolatedConformances
  -enable-upcoming-feature ExistentialAny
  -enable-upcoming-feature InternalImportsByDefault
  "$optimize"
)

archs="${ARCHS:-$(uname -m)}"
slices=()
for arch in $archs; do
  out="$work/$arch"
  rm -rf "$out"
  mkdir -p "$out"
  target="$arch-apple-macos$min_macos"
  xcrun swiftc "${swift_flags[@]}" -target "$target" -parse-as-library \
    -module-name CmuxNextServerHelper -emit-module -emit-module-path "$out/CmuxNextServerHelper.swiftmodule" \
    -emit-library -static -o "$out/libCmuxNextServerHelper.a" \
    "$sources"/CmuxNextServerHelper/*.swift
  xcrun swiftc "${swift_flags[@]}" -target "$target" -module-name cmux_server_helper \
    -I "$out" -L "$out" -lCmuxNextServerHelper \
    -o "$out/cmux-server-helper" "$sources/CmuxNextServerHelperDaemon/main.swift"
  slices+=("$out/cmux-server-helper")
done

mkdir -p "$(dirname "$helper")" "$(dirname "$plist")"
rm -f "$helper"
if [[ "${#slices[@]}" -eq 1 ]]; then
  cp "${slices[0]}" "$helper"
else
  lipo -create -output "$helper" "${slices[@]}"
fi
chmod 0755 "$helper"

# BundleProgram is relative to the app bundle (SMAppService); no absolute path.
plutil -create xml1 "$plist.tmp"
plutil -insert Label -string "$label" "$plist.tmp"
plutil -insert BundleProgram -string "Contents/Resources/libexec/cmux-server-helper" "$plist.tmp"
plutil -insert ProgramArguments -array "$plist.tmp"
plutil -insert ProgramArguments -string "cmux-server-helper" -append "$plist.tmp"
plutil -insert ProgramArguments -string "--app" -append "$plist.tmp"
plutil -insert ProgramArguments -string "$bundle_id" -append "$plist.tmp"
plutil -insert MachServices -dictionary "$plist.tmp"
plutil -insert "MachServices.${label//./\\.}" -bool YES "$plist.tmp"
plutil -insert AssociatedBundleIdentifiers -array "$plist.tmp"
plutil -insert AssociatedBundleIdentifiers -string "$bundle_id" -append "$plist.tmp"
plutil -lint "$plist.tmp" >/dev/null
mv -f "$plist.tmp" "$plist"

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --identifier cmux-server-helper --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$helper" >/dev/null
fi
echo "bundle-server-helper: $label ($archs)"
