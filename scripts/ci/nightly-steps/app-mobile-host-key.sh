#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Resolve the iPhone host build identity". Kept out of the workflow
# for its size budget (tests/test_workflow_file_size.py); the step's env: sets every input.
# Adds this builder's Rust, SDK, clang and Cargo identity to the portable source key
# (scripts/ci/nightly_mobile_host_reuse.py). No key leaves the build on its normal source path.
set -uo pipefail
scripts/ci/clear-dirs.sh "$GITHUB_WORKSPACE/.nightly-mobile-host"
if [ -n "${SOURCE_KEY:-}" ] && [ -f scripts/ci/nightly_mobile_host_reuse.py ]; then
  python3 scripts/ci/nightly_mobile_host_reuse.py builder-key --source-key "$SOURCE_KEY" \
    --archs "$NIGHTLY_COMPILE_ARCHS" >> "$GITHUB_OUTPUT"
fi
