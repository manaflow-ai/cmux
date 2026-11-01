#!/usr/bin/env bash
# nightly.yml build-nightly-ghostty-cli-helper: "Build the cmux-next source archive". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
if ! ZIG_GLOBAL_CACHE_DIR="$HOME/.cache/zig" \
  ./scripts/cmux-next/build-ghostty-source-archive.sh "$RUNNER_TEMP/source-archive"; then
  echo "::error title=cmux-next source archive failed::If the log names a Ghostty package without a license file, review its upstream license and pin the text in cmux-tui/build-support/notices/ghostty/pinned-licenses/MANIFEST.json (update PINNED_MANIFEST_SHA256 in collect-ghostty-licenses.py). nightly-next does not ship without the Ghostty license tree."
  exit 1
fi
