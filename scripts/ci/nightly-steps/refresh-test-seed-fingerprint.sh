#!/usr/bin/env bash
# nightly.yml refresh-test-compilation-cache: "Compute the DerivedData seed fingerprint". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
echo "fingerprint=$(scripts/ci/compile-app-host-test-product.sh canonical-fingerprint "$CMUX_COMPILE_ADMISSION_DERIVED_DATA")" >> "$GITHUB_OUTPUT"
