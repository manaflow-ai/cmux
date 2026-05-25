#!/usr/bin/env bash
# Regenerate the Xcode project from project.yml using XcodeGen.
#
# Install: brew install xcodegen
#
# This script is intentionally minimal — it does NOT touch a .xcodeproj on
# disk other than via xcodegen. Any local Xcode tinkering you do will be
# overwritten the next time you run `xcodegen generate`.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed. Install with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate
echo "Generated cmux-remote.xcodeproj — open with: open cmux-remote.xcodeproj"
