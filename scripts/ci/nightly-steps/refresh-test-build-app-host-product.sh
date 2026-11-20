#!/usr/bin/env bash
# nightly.yml refresh-test-compilation-cache: "Build the app-host test product". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
scripts/ci/compile-app-host-test-product.sh canonical-build \
  "$CMUX_COMPILE_ADMISSION_DERIVED_DATA" \
  "$PWD/.ci-source-packages" \
  "$CMUX_COMPILE_ADMISSION_CAS"
