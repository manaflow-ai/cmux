#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/Packages/macOS/CmuxTerminalRenderer"
EXECUTABLE="${1:-}"

if [[ -z "$EXECUTABLE" ]]; then
  SCRATCH_PATH="${CMUX_RENDERER_TEST_SCRATCH:-$REPO_ROOT/.build/terminal-renderer-integration}"
  xcrun swift build \
    --package-path "$PACKAGE_DIR" \
    --scratch-path "$SCRATCH_PATH" \
    --configuration debug \
    --product cmux-terminal-renderer
  BIN_PATH="$(xcrun swift build \
    --package-path "$PACKAGE_DIR" \
    --scratch-path "$SCRATCH_PATH" \
    --configuration debug \
    --show-bin-path)"
  EXECUTABLE="$BIN_PATH/cmux-terminal-renderer"
fi

[[ -x "$EXECUTABLE" ]] || {
  echo "error: renderer helper is not executable: $EXECUTABLE" >&2
  exit 1
}

if rg -n 'ghostty_(surface_|app_new)' \
  "$PACKAGE_DIR/Sources/CmuxTerminalRendererWorker"; then
  echo "error: renderer helper source instantiates Ghostty app/surface APIs" >&2
  exit 1
fi

/usr/bin/python3 "$SCRIPT_DIR/test-terminal-renderer-helper.py" "$EXECUTABLE"
