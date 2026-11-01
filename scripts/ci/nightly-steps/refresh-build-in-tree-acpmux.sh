#!/usr/bin/env bash
# nightly.yml refresh-compilation-cache: "Build in-tree acpmux for the compilation cache". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
acpmux_bin="$RUNNER_TEMP/cmux-next-acpmux/acpmux"
scripts/cmux-next/build-acpmux.sh --output "$acpmux_bin"
echo "CMUX_NEXT_ACPMUX_BIN=$acpmux_bin" >> "$GITHUB_ENV"
