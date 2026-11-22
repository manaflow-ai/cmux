#!/usr/bin/env bash
# nightly.yml prepare-nightly-variant-primary: "Inject universal Ghostty CLI helper". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
APP_DIR="build-universal/Build/Products/Release/cmux.app"
if [ ! -d "$APP_DIR" ]; then
  echo "Built app not found at $APP_DIR" >&2
  exit 1
fi
DEST="$APP_DIR/Contents/Resources/bin/ghostty"
mkdir -p "$(dirname "$DEST")"
install -m 755 nightly-inputs/ghostty/ghostty "$DEST"
echo "Injected Ghostty CLI helper architectures: $(lipo -archs "$DEST")"
