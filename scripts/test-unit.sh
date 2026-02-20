#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="${CMUX_XCODE_PROJECT:-cmux.xcodeproj}"
if [ ! -d "$PROJECT" ]; then
  DISCOVERED_PROJECT="$(find . -maxdepth 1 -type d -name '*.xcodeproj' | sort | head -n 1 | sed 's#^\\./##')"
  if [ -n "$DISCOVERED_PROJECT" ]; then
    PROJECT="$DISCOVERED_PROJECT"
  else
    echo "ERROR: Xcode project not found in repo root." >&2
    exit 1
  fi
fi

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
