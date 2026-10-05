#!/usr/bin/env bash
# Compile the cmux app scheme (cmux.xcodeproj: the app host and every local
# package it links, CmuxControlSocket among them) in Debug for arm64, the way
# a tagged dev build compiles it, without signing, CEF or the zig CLI.
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
#   default derived data: /tmp/cmux-scheme-compile. A kept path builds
#   incrementally; precompiled modules a different checkout left there are
#   dropped and the build retried once, as the fleet's dev builds do.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
derived_data="${1:-/tmp/cmux-scheme-compile}"

echo "check-cmux-scheme-compile: $(xcodebuild -version | tr '\n' ' ')"
cd "$repo_root"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
build() {
  CMUX_NEXT_SKIP_CEF=1 CMUX_SKIP_ZIG_BUILD=1 \
    "$repo_root/scripts/ci/run-xcodebuild-with-diagnostics.sh" -- \
    xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}
status=0
build || status=$?
if (( status )) && "$repo_root/scripts/cmux-next/stale-pcm-retry-needed.sh" "$log"; then
  echo "check-cmux-scheme-compile: stale precompiled modules in $derived_data; removing them and building again"
  "$repo_root/scripts/cmux-next/clear-stale-scheme-build-state.sh" "$derived_data"
  status=0
  build || status=$?
fi
exit "$status"
