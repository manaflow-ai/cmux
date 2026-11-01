#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Build the web bundles (cmux-next)". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
if python3 scripts/ci/nightly_inputs.py install-web "$RUNNER_TEMP/nightly-inputs/web"; then
  exit 0
else
  status=$?
fi
[ "$status" = 3 ] || echo "::warning title=Web bundles hand-off::installing the handed-off web bundles failed (status $status); building them here"
scripts/cmux-next/build-web-bundles.sh --force
