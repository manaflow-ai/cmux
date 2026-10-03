#!/usr/bin/env bash
# The cmux server's privileged helper (plans/cmux-next/server.md 9.4).
#
#   Contents/Resources/libexec/cmux-server-helper           the helper (root, launchd)
#   Contents/Library/LaunchDaemons/com.cmux.server.helper.plist
#
# Two modes:
#   bundle-server-helper.sh                 Xcode phase "Bundle server helper": compiles the
#                                           helper into the built app, then stamps it.
#   bundle-server-helper.sh --stamp <app>   writes (or removes) the LaunchDaemon plist from the
#                                           app's FINAL CFBundleIdentifier. scripts/sign-cmux-bundle.sh
#                                           runs it before signing, because nightly and RC builds
#                                           change the bundle id after the build (prepare_variant).
#
# The app registers the plist with SMAppService.daemon; the user approves it once
# in System Settings > Login Items. The plist names a per-build label
# (`<bundle id>.server-helper`) and passes `--app <bundle id>`, so each build has
# its own helper and the helper serves only the app that carries it, signed by
# the helper's own team. Stable builds (com.cmuxterm.app) carry no helper: the
# server actions are DEV and NIGHTLY only. Tagged DEV builds are signed ad hoc by
# scripts/reload.sh, so their helper refuses every client (by design); the helper
# path is testable only in a team-signed build.
#
# The helper is compiled with swiftc from Packages/macOS/CmuxNext/Sources/
# CmuxNextServerHelper (no package dependencies) and CmuxNextServerHelperDaemon/
# main.swift, one slice per arch in $ARCHS: resolving the whole CmuxNext package
# for one small executable would fetch every remote dependency inside the phase.
# scripts/sign-cmux-bundle.sh signs it for Developer ID with no entitlements;
# here it gets the build's identity. Its identifier is cmux-server-helper (the
# file name) in both places.
set -euo pipefail

# Writes or removes the LaunchDaemon plist for the app at $1 from its final bundle id.
stamp() {
  local app="$1" contents bundle_id label helper plist
  contents="$app/Contents"
  helper="$contents/Resources/libexec/cmux-server-helper"
  plist="$contents/Library/LaunchDaemons/com.cmux.server.helper.plist"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents/Info.plist")"
  if [[ "$bundle_id" == "com.cmuxterm.app" || ! -e "$helper" ]]; then
    rm -f "$helper" "$plist"
    rmdir "$contents/Library/LaunchDaemons" 2>/dev/null || true
    echo "bundle-server-helper: no server helper in $bundle_id"
    return 0
  fi
  if [[ ! "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
    echo "error: bundle-server-helper: bundle id '$bundle_id' is not a plain reverse-DNS name" >&2
    return 1
  fi
  label="$bundle_id.server-helper"
  mkdir -p "$(dirname "$plist")"
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
  echo "bundle-server-helper: $label"
}

if [[ "${1:-}" == "--stamp" ]]; then
  stamp "${2:?usage: bundle-server-helper.sh --stamp <app>}"
  exit 0
fi

app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
helper="$app/Contents/Resources/libexec/cmux-server-helper"

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

mkdir -p "$(dirname "$helper")"
rm -f "$helper"
if [[ "${#slices[@]}" -eq 1 ]]; then
  cp "${slices[0]}" "$helper"
else
  lipo -create -output "$helper" "${slices[@]}"
fi
chmod 0755 "$helper"

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --identifier cmux-server-helper --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$helper" >/dev/null
fi
stamp "$app"
