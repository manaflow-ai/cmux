#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib/cmux-paths.sh"
cmux_paths_init "$SCRIPT_DIR/../scripts/reload.sh"

SCHEME_FILE="$CMUX_XCODE_PROJECT_PATH/xcshareddata/xcschemes/cmux.xcscheme"

if [ ! -f "$SCHEME_FILE" ]; then
  echo "FAIL: Missing scheme file at $SCHEME_FILE" >&2
  exit 1
fi

if ! grep -q '<TestAction buildConfiguration="Debug"' "$SCHEME_FILE"; then
  echo "FAIL: cmux scheme TestAction must use Debug build configuration for UI test setup hooks" >&2
  exit 1
fi

echo "PASS: cmux scheme TestAction uses Debug"
