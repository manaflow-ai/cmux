#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Archive unsigned nightly app". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
products="build-universal/Build/Products/Release"
if [ ! -d "$products/cmux.app" ]; then
  echo "Built app not found at $products/cmux.app" >&2
  exit 1
fi
tar -C "$products" -czf "$RUNNER_TEMP/cmux-nightly-unsigned.tar.gz" cmux.app
