#!/usr/bin/env bash
# nightly.yml refresh-test-compilation-cache: "Resolve Swift packages". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
scripts/ci/compile-app-host-test-product.sh canonical-resolve \
  "$CMUX_COMPILE_ADMISSION_DERIVED_DATA" "$PWD/.ci-source-packages"
