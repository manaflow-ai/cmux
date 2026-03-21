#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/cmux-paths.sh"
cmux_paths_init "${BASH_SOURCE[0]}"

cd "$CMUX_REPO_ROOT"

PROJECT="$CMUX_XCODE_PROJECT_PATH"
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
