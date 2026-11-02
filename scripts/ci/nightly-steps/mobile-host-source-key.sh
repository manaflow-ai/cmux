#!/usr/bin/env bash
# nightly.yml resolve-nightly-cmux-tui-client: "Source key of the iPhone host". Kept out of the
# workflow for its size budget (tests/test_workflow_file_size.py); the step's env: sets every input.
# Portable key of the iPhone host's sources at the build revision (git objects only), computed
# before a Mac is allocated; the builder adds its own toolchain identity.
set -euo pipefail
key="$(python3 scripts/ci/nightly_mobile_host_reuse.py source-key --revision "$BUILD_SHA" --archs "$ARCHS")"
echo "key=$key" >> "$GITHUB_OUTPUT"
