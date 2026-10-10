#!/usr/bin/env bash
# Compile the cmux app scheme (cmux.xcodeproj: the app host and every local
# package it links, CmuxControlSocket among them) for arm64, without signing,
# CEF or the zig CLI. The default remains the Debug cmux DEV build used by
# dogfood; CMUX_NEXT_CONFIGURATION and the product overrides are used by the
# separate Release cmux NEXT DEV channel.
#
# Why: the cmux-next package checks build CmuxNext only. A merge from main
# once re-added files to CmuxControlSocket that extend types this branch had
# deleted, and nothing failed until fleet dev builds did (exit 65).
#
# GhosttyNextKit comes from SwiftPM (Packages/Shared/CmuxGhosttyKit). Needs
# the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch), which the
# Bundle cmux-tui phase copies instead of building it from source.
#
# Usage: scripts/cmux-next/check-cmux-scheme-compile.sh [derived-data-path]
#   default derived data: a new directory in $TMPDIR (per fleet step),
#   removed when the script ends. Never a host-shared fixed path: explicit
#   precompiled modules are keyed by compile arguments, not header content, so
#   a kept host-wide DerivedData reused modules built from an older xcframework
#   header (check-release-compile.sh failed this way on cmuxs-Mac-mini-4,
#   2026-10-06). A caller's path (the glaeda job's per-runner cache) builds
#   incrementally and is kept; precompiled modules a different checkout left
#   there are dropped and the build retried once, as the fleet's dev builds
#   do. A fresh directory has no such modules, so it is never retried.
set -euo pipefail

# xcodebuild compiles the app: fleet or GitHub runner only.
# shellcheck source-path=SCRIPTDIR source=lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fleet-only.sh"
cmux_next_require_fleet check-cmux-scheme-compile.sh "xcodebuild" "cmux app scheme compile (Debug)"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
configuration="${CMUX_NEXT_CONFIGURATION:-Debug}"
product_name="${CMUX_NEXT_PRODUCT_NAME:-}"
bundle_id="${CMUX_NEXT_BUNDLE_ID:-}"
code_sign_entitlements="${CMUX_NEXT_CODE_SIGN_ENTITLEMENTS:-}"
auth_callback_scheme="${CMUX_NEXT_AUTH_CALLBACK_SCHEME:-}"
case "$configuration" in
  Debug|Release) ;;
  *) echo "check-cmux-scheme-compile: unsupported configuration '$configuration'" >&2; exit 2 ;;
esac
kept_path=0
if [[ -n "${1:-}" ]]; then
  derived_data="$1"
  kept_path=1
else
  derived_data="$(mktemp -d "${TMPDIR:-/tmp}/cmux-scheme-compile.XXXXXX")"
fi

echo "check-cmux-scheme-compile: $(xcodebuild -version | tr '\n' ' ')"
cd "$repo_root"
log="$(mktemp)"
if (( kept_path )); then
  trap 'rm -f "$log"' EXIT
else
  trap 'rm -f "$log"; rm -rf -- "$derived_data"' EXIT
fi
build() {
  xcode_args=(
    -project cmux.xcodeproj -scheme cmux -configuration "$configuration"
    -destination 'platform=macOS,arch=arm64'
    -derivedDataPath "$derived_data"
    ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO
  )
  [[ -n "$product_name" ]] && xcode_args+=("PRODUCT_NAME=$product_name")
  [[ -n "$bundle_id" ]] && xcode_args+=("PRODUCT_BUNDLE_IDENTIFIER=$bundle_id")
  [[ -n "$code_sign_entitlements" ]] && xcode_args+=("CODE_SIGN_ENTITLEMENTS=$code_sign_entitlements")
  [[ -n "$auth_callback_scheme" ]] && xcode_args+=("CMUX_AUTH_CALLBACK_SCHEME=$auth_callback_scheme")
  CMUX_NEXT_SKIP_CEF=1 CMUX_SKIP_ZIG_BUILD=1 \
    "$repo_root/scripts/ci/run-xcodebuild-with-diagnostics.sh" -- \
    xcodebuild "${xcode_args[@]}" \
    build 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}
status=0
build || status=$?
if (( status && kept_path )) && "$repo_root/scripts/cmux-next/stale-pcm-retry-needed.sh" "$log"; then
  echo "check-cmux-scheme-compile: stale precompiled modules in $derived_data; removing them and building again"
  "$repo_root/scripts/cmux-next/clear-stale-scheme-build-state.sh" "$derived_data"
  status=0
  build || status=$?
fi
exit "$status"
