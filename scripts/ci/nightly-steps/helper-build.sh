#!/usr/bin/env bash
# nightly.yml build-nightly-ghostty-cli-helper: "Build Ghostty CLI helper". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
echo "Ghostty CLI helper cache: ${HELPER_CACHE_HIT:-false}" | tee -a "$GITHUB_STEP_SUMMARY"
mkdir -p nightly-helper
if [[ "$NIGHTLY_COMPILE_ARCHS" == "arm64" ]]; then
  ./scripts/build-ghostty-cli-helper.sh --target aarch64-macos --output nightly-helper/ghostty
  lipo nightly-helper/ghostty -verify_arch arm64
else
  ./scripts/build-ghostty-cli-helper.sh --universal --output nightly-helper/ghostty
  lipo nightly-helper/ghostty -verify_arch arm64 x86_64
fi
# The provenance line resolve-nightly-ghostty-cli-helper reads later.
echo "ghostty-cli-helper-build=$(git rev-parse HEAD)"
