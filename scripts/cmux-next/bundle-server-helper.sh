#!/usr/bin/env bash
# The cmux server's launchd jobs (plans/cmux-next/server.md 4.3, 9.4):
#
#   Contents/Resources/libexec/cmux-server-helper           the helper (root, launchd)
#   Contents/Library/LaunchDaemons/com.cmux.server.helper.plist
#   Contents/Library/LaunchAgents/com.cmux.server.plist     the server (`cmux host run`)
#
# Two modes:
#   bundle-server-helper.sh                 Xcode phase "Bundle server helper": compiles the
#                                           helper into the built app, then stamps it.
#   bundle-server-helper.sh --stamp <app>   writes (or removes) both plists from the
#                                           app's FINAL CFBundleIdentifier. scripts/sign-cmux-bundle.sh
#                                           runs it before signing, because nightly and RC builds
#                                           change the bundle id after the build (prepare_variant)
#                                           and release jobs install the cmux CLI after the build.
#
# The app registers the helper plist with SMAppService.daemon and the server
# plist with SMAppService.agent (ServerLaunchAgent); the user approves them once
# in System Settings > Login Items. Each plist names a per-build label
# (`<bundle id>.server-helper`, `<bundle id>.server`), so each build has its own
# jobs. The helper gets `--app <bundle id>` and serves only the app that carries
# it, signed by the helper's own team. Stable builds (com.cmuxterm.app) carry
# neither: the server actions are DEV and NIGHTLY only. Tagged DEV builds are
# signed ad hoc by scripts/reload.sh, so their helper refuses every client (by
# design); the helper path is testable only in a team-signed build.
#
# The server agent runs the bundled cmux CLI (Contents/Resources/bin/cmux, put
# there by "Bundle cmux-tui" or by install-cmux-tui-client.sh) as the frozen
# unit command `cmux host run`. A bundle without that binary gets no agent
# plist, so the app reports that the server is not in this build. The plist
# holds no environment, no secrets and no per-user path (it is sealed in a
# bundle every user of the Mac shares; launchd does not expand `~`), so it sets
# no StandardOutPath: `cmux host run` writes its own log under the server
# state folder. KeepAlive restarts the job when it exits; a CLI without
# `host run` therefore exits and is restarted (launchd throttles it to once per
# 10 s) until the server stack ships in the bundled binary.
#
# The helper is compiled with swiftc from Packages/macOS/CmuxNext/Sources/
# CmuxNextServerHelper (no package dependencies) and CmuxNextServerHelperDaemon/
# main.swift, one slice per arch in $ARCHS: resolving the whole CmuxNext package
# for one small executable would fetch every remote dependency inside the phase.
# scripts/sign-cmux-bundle-helpers.sh signs it for Developer ID with no
# entitlements; here it gets the build's identity. Its identifier is
# cmux-server-helper (the file name) in both places. The plists are resources
# sealed by the app signature; they carry no signature of their own.
set -euo pipefail

# Writes or removes both plists for the app at $1 from its bundle id.
# $2 = "build" (the Xcode phase): a Release build is built as com.cmuxterm.app and
# may still become NIGHTLY or RC, so it keeps the jobs; only the signing stamp
# (no $2) drops them from a stable bundle.
stamp() {
  local app="$1" phase="${2:-sign}" contents bundle_id drop=0
  contents="$app/Contents"
  # The Xcode phase uses the build's own bundle id: Xcode may write the
  # processed Info.plist after the script phases (a rebuild of an existing
  # tag found none). Signing reads the final id from the finished bundle.
  if [[ "$phase" == "build" && -n "${PRODUCT_BUNDLE_IDENTIFIER:-}" ]]; then
    bundle_id="$PRODUCT_BUNDLE_IDENTIFIER"
  else
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents/Info.plist")"
  fi
  [[ "$bundle_id" == "com.cmuxterm.app" && "$phase" != "build" ]] && drop=1
  if [[ "$drop" == 0 && ! "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
    echo "error: bundle-server-helper: bundle id '$bundle_id' is not a plain reverse-DNS name" >&2
    return 1
  fi
  stamp_helper "$contents" "$bundle_id" "$drop"
  stamp_agent "$contents" "$bundle_id" "$drop"
}

# Starts a plist at $1.tmp with Label $2, BundleProgram $3 (relative to the app
# bundle, as SMAppService requires) and AssociatedBundleIdentifiers [$4].
plist_begin() {
  plutil -create xml1 "$1.tmp"
  plutil -insert Label -string "$2" "$1.tmp"
  plutil -insert BundleProgram -string "$3" "$1.tmp"
  plutil -insert AssociatedBundleIdentifiers -array "$1.tmp"
  plutil -insert AssociatedBundleIdentifiers -string "$4" -append "$1.tmp"
  plutil -insert ProgramArguments -array "$1.tmp"
}

plist_commit() {
  plutil -lint "$1.tmp" >/dev/null
  mv -f "$1.tmp" "$1"
}

stamp_helper() {
  local contents="$1" bundle_id="$2" drop="$3" helper plist label
  helper="$contents/Resources/libexec/cmux-server-helper"
  plist="$contents/Library/LaunchDaemons/com.cmux.server.helper.plist"
  if [[ "$drop" == 1 || ! -e "$helper" ]]; then
    rm -f "$helper" "$plist"
    rmdir "$contents/Library/LaunchDaemons" 2>/dev/null || true
    echo "bundle-server-helper: no server helper in $bundle_id"
    return 0
  fi
  label="$bundle_id.server-helper"
  mkdir -p "$(dirname "$plist")"
  plist_begin "$plist" "$label" "Contents/Resources/libexec/cmux-server-helper" "$bundle_id"
  plutil -insert ProgramArguments -string "cmux-server-helper" -append "$plist.tmp"
  plutil -insert ProgramArguments -string "--app" -append "$plist.tmp"
  plutil -insert ProgramArguments -string "$bundle_id" -append "$plist.tmp"
  plutil -insert MachServices -dictionary "$plist.tmp"
  plutil -insert "MachServices.${label//./\\.}" -bool YES "$plist.tmp"
  plist_commit "$plist"
  echo "bundle-server-helper: $label"
}

stamp_agent() {
  local contents="$1" bundle_id="$2" drop="$3" program="Contents/Resources/bin/cmux" plist label
  plist="$contents/Library/LaunchAgents/com.cmux.server.plist"
  if [[ "$drop" == 1 || ! -f "${contents%/Contents}/$program" ]]; then
    rm -f "$plist"
    rmdir "$contents/Library/LaunchAgents" 2>/dev/null || true
    echo "bundle-server-helper: no server agent in $bundle_id"
    return 0
  fi
  label="$bundle_id.server"
  mkdir -p "$(dirname "$plist")"
  plist_begin "$plist" "$label" "$program" "$bundle_id"
  plutil -insert ProgramArguments -string "$program" -append "$plist.tmp"
  plutil -insert ProgramArguments -string host -append "$plist.tmp"
  plutil -insert ProgramArguments -string run -append "$plist.tmp"
  plutil -insert RunAtLoad -bool YES "$plist.tmp"
  plutil -insert KeepAlive -bool YES "$plist.tmp"
  # Standard, not Background: the job hosts the user's terminals and app
  # servers, which must not run under background CPU and I/O limits. Same as
  # the cmux-server-core launchd golden.
  plutil -insert ProcessType -string Standard "$plist.tmp"
  plist_commit "$plist"
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
stamp "$app" build
