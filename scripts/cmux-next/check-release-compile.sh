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
# Usage: scripts/cmux-next/check-release-compile.sh [derived-data-path]
#   default derived data: /tmp/cmux-next-release-compile
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
derived_data="${1:-/tmp/cmux-next-release-compile}"

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

echo "check-release-compile: $(xcodebuild -version | tr '\n' ' ')"
cd "$repo_root/Packages/macOS/CmuxNext"
exec "$repo_root/scripts/ci/run-xcodebuild-with-diagnostics.sh" -- \
  xcodebuild -scheme CmuxNextApp -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO \
  build
