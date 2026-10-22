#!/usr/bin/env bash
# Compile the cmux-next package (scheme CmuxNextApp and everything
# it links) in the Release configuration with the Xcode the nightly uses, the
# way the nightly app build compiles it: xcodebuild, -O, whole-module.
#
# Why: `swift build --build-tests` (Debug) and the local Xcode 27 accept code
# that Swift 6.2 (Xcode 26) rejects in Release, for example a class whose
# isolation comes only from `.defaultIsolation(MainActor.self)` and that has an
# `isolated deinit`, or newer type inference. Those failures then appear only
# in the nightly, about 20 minutes in. This compiles one architecture, so it is
# a compile check, not a universal build.
#
# Xcode: DEVELOPER_DIR when set (CI sets it with scripts/select-ci-xcode.sh),
# else CMUX_RELEASE_COMPILE_XCODE (an .app path), else
# /Applications/Xcode_<version>.app for the macOS 26 pool pin in
# scripts/ci/xcode-pins.txt (the nightly's Xcode). Other Xcode 26 releases are
# not equivalent: Xcode 26.3 rejects `Bundle.module` in nonisolated code that
# Xcode 26.6 accepts. Package.swift needs tools 6.2, so Swift 6.0 (the
# legacy-app rule in skills/cmux-architecture/references/swift-6-0-compatibility.md)
# does not apply to this package.
#
# Usage: scripts/cmux-next/check-release-compile.sh [--archs arm64|x86_64] [derived-data-path]
#   --archs: the architecture to compile (default arm64). nightly-next ships an
#   x86_64 app too, so `--archs x86_64` checks the Intel compile the same way.
#   default derived data: a new directory in $TMPDIR (per fleet step), removed
#   when the script ends. Never a host-shared fixed path: explicit precompiled
#   modules (SwiftExplicitPrecompiledModules/*.pcm) are keyed by the compile
#   arguments, not by header content, so a kept DerivedData reused a CCmuxRdFFI
#   module built from an older CCmuxAppFFI xcframework header and failed with
#   "cmux_rd_ffi.h has been modified since the module file was built"
#   (cmuxs-Mac-mini-4, 2026-10-06). A per-checksum key would not cover
#   path-based or remote-package binary targets, and two steps on one host
#   would share one build database. Downloaded packages and binary artifacts
#   stay warm in SwiftPM's own content-addressed cache. A caller that passes a
#   path owns it and keeps it. CI uses a worker/workspace/toolchain-specific
#   Release path on owned runners; the binary-module guard and the one-time
#   stale-module recovery keep it correct as in check-cmux-scheme-compile.sh.
set -euo pipefail

# xcodebuild compiles the app: fleet or GitHub runner only.
# shellcheck source-path=SCRIPTDIR source=lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fleet-only.sh"
cmux_next_require_fleet check-release-compile.sh "xcodebuild" "cmux-next Release compile (Xcode 26)"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
archs=arm64
if [[ "${1:-}" == --archs ]]; then
  case "${2:-}" in
    arm64|x86_64) archs="$2" ;;
    *) echo "check-release-compile: --archs takes arm64 or x86_64, got '${2:-}'" >&2; exit 2 ;;
  esac
  shift 2
fi
# --archs comes first; anything else after the path would be ignored silently.
if (( $# > 1 )); then
  echo "check-release-compile: usage: check-release-compile.sh [--archs arm64|x86_64] [derived-data-path]" >&2
  exit 2
fi
kept_path=0
if [[ -n "${1:-}" ]]; then
  derived_data="$1"
  kept_path=1
else
  derived_data="$(mktemp -d "${TMPDIR:-/tmp}/cmux-next-release-compile.XXXXXX")"
fi
log="$(mktemp)"
if (( kept_path )); then
  trap 'rm -f "$log"' EXIT
else
  trap 'rm -f "$log"; rm -rf -- "$derived_data"' EXIT
fi

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  xcode_app="${CMUX_RELEASE_COMPILE_XCODE:-}"
  if [[ -z "$xcode_app" ]]; then
    pinned="$(awk '$1 == "26" { print $2 }' "$repo_root/scripts/ci/xcode-pins.txt")"
    xcode_app="/Applications/Xcode_${pinned}.app"
  fi
  if [[ ! -d "$xcode_app" ]]; then
    echo "check-release-compile: $xcode_app is not installed. Install it, set CMUX_RELEASE_COMPILE_XCODE, or rely on the CI job 'cmux-next Release compile (Xcode 26)'" >&2
    exit 2
  fi
  export DEVELOPER_DIR="$xcode_app/Contents/Developer"
fi

echo "check-release-compile: $(xcodebuild -version | tr '\n' ' ')(ARCHS=$archs)"
cd "$repo_root/Packages/macOS/CmuxNext"
build() {
  "$repo_root/scripts/ci/run-xcodebuild-with-diagnostics.sh" -- \
    xcodebuild -scheme CmuxNextApp -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    ARCHS="$archs" ONLY_ACTIVE_ARCH=NO \
    COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}
if (( kept_path )); then
  # A binary target's headers changed since the last build there: build cold
  # (scripts/ci/swiftpm-binary-module-guard.sh, xcode_binary_module_guard).
  # shellcheck source=scripts/ci/swiftpm-binary-module-guard.sh
  source "$repo_root/scripts/ci/swiftpm-binary-module-guard.sh"
  xcode_binary_module_guard "$repo_root/Packages/macOS/CmuxNext" "$derived_data" -scheme CmuxNextApp
fi
status=0
build || status=$?
if (( status && kept_path )) && "$repo_root/scripts/cmux-next/stale-pcm-retry-needed.sh" "$log"; then
  echo "check-release-compile: stale precompiled modules in $derived_data; removing them and building again"
  "$repo_root/scripts/cmux-next/clear-stale-scheme-build-state.sh" "$derived_data"
  status=0
  build || status=$?
fi
exit "$status"
