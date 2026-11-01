#!/usr/bin/env bash
# nightly.yml refresh-test-compilation-cache: "Collect resolved Swift packages". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
resolved="$CMUX_CI_CANONICAL_ROOT/src/.ci-source-packages"
test -d "$resolved/.package-cache"
rsync -a --delete "$resolved/" .ci-source-packages/
