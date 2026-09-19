#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SWIFTPM_MIRROR_CONFIG="${SWIFTPM_MIRROR_CONFIG:-$SCRIPT_DIR/../Packages/macOS/CMUXProjectModel/.swiftpm/configuration/mirrors.json}"
cd "$SCRIPT_DIR/.."

PROJECT="cmux.xcodeproj"
SCHEME="cmux-unit"
CONFIGURATION="${CMUX_TEST_CONFIGURATION:-Debug}"
DESTINATION="${CMUX_TEST_DESTINATION:-platform=macOS}"

# Default to `test` when no explicit xcodebuild action is provided.
if [ "$#" -eq 0 ]; then
  set -- test
fi

exec xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  "$@"
