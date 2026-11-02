#!/usr/bin/env bash
# nightly.yml resolve-nightly-cmux-tui-client: "Resolve the original cmux-tui tree". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
git fetch --no-tags origin "$SOURCE_SHA"
echo "key=$(python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$SOURCE_SHA")" >> "$GITHUB_OUTPUT"
