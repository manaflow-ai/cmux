#!/usr/bin/env bash
# nightly.yml refresh-test-compilation-cache: "Prepare admission build paths". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
# The same paths as ci.yml `macos-compile-admission`: they are part of
# every cache entry this job writes.
# A self-hosted Mac can have several runners. Derive one root per
# RUNNER_NAME before cleanup so one seed build cannot remove another
# runner's source tree, DerivedData, or compilation CAS.
root="$(scripts/ci/canonical-build-root.sh --print-root)"
scripts/ci/clear-dirs.sh "$root/derived-data-compile-admission" "$root/compile-admission-cas"
{
  echo "CMUX_CI_CANONICAL_ROOT=$root"
  echo "CMUX_COMPILE_ADMISSION_DERIVED_DATA=$root/derived-data-compile-admission"
  echo "CMUX_COMPILE_ADMISSION_CAS=$root/compile-admission-cas"
} >> "$GITHUB_ENV"
