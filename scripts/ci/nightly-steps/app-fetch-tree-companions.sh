#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Fetch the resolved cmux-tui tree companions". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
scripts/cmux-next/pin-cmux-tui.sh fetch-acpmux
acpmux_bin="$(scripts/cmux-next/pin-cmux-tui.sh acpmux-path)"
[[ -x "$acpmux_bin" ]] || { echo "error: fetched tree has no executable acpmux companion" >&2; exit 1; }
echo "CMUX_NEXT_ACPMUX_BIN=$acpmux_bin" >> "$GITHUB_ENV"
echo "Using attested same-tree acpmux companion: $acpmux_bin"
