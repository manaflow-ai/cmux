#!/usr/bin/env bash
# Compile the cmux-next package (CmuxNextApp and everything it links) in the
# Release configuration with the oldest Xcode the nightly uses, the way the
# nightly app build compiles it: xcodebuild, -O, whole-module.
#
# Why: `swift build --build-tests` (Debug) and the local Xcode 27 accept code
# that Swift 6.2 (Xcode 26) rejects in Release, for example a class whose
# isolation comes only from `.defaultIsolation(MainActor.self)` and that has an
# `isolated deinit`, or newer type inference. Those failures then appear only
# in the nightly, about 20 minutes in. This compiles one architecture, so it is
# a compile check, not a universal build.
#
# Xcode: DEVELOPER_DIR when set (CI sets it with scripts/select-ci-xcode.sh),
# else CMUX_RELEASE_COMPILE_XCODE (an .app path), else the oldest installed
# /Applications/Xcode_26*.app. Package.swift needs tools 6.2, so Xcode 26.0 is
# the oldest Xcode that can build cmux-next at all; Swift 6.0 (the legacy-app
# rule in skills/cmux-architecture/references/swift-6-0-compatibility.md) does
# not apply to this package.
#
# Usage: scripts/cmux-next/check-release-compile.sh [derived-data-path]
#   default derived data: /tmp/cmux-next-release-compile
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
derived_data="${1:-/tmp/cmux-next-release-compile}"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  xcode_app="${CMUX_RELEASE_COMPILE_XCODE:-}"
  if [[ -z "$xcode_app" ]]; then
    xcode_app="$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | head -n 1 || true)"
  fi
  if [[ -z "$xcode_app" || ! -d "$xcode_app" ]]; then
    echo "check-release-compile: no Xcode 26 found; set CMUX_RELEASE_COMPILE_XCODE=/Applications/Xcode_26.x.app" >&2
    exit 2
  fi
  export DEVELOPER_DIR="$xcode_app/Contents/Developer"
fi

if [[ ! -e "$repo_root/GhosttyKit.xcframework" ]]; then
  echo "check-release-compile: $repo_root/GhosttyKit.xcframework is missing; run scripts/download-prebuilt-ghosttykit.sh or scripts/ensure-ghosttykit.sh" >&2
  exit 2
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
