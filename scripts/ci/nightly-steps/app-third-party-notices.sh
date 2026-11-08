#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Generate third-party notices (cmux-next)". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
if python3 scripts/ci/nightly_inputs.py install-notices "$RUNNER_TEMP/nightly-inputs/notices"; then
  status=0
else
  status=$?
fi
if [ "$status" != 0 ]; then
  [ "$status" = 3 ] || echo "::warning title=Notices hand-off::taking the handed-off notices failed (status $status); generating them here"
  # A trusted NEXT worker keeps the crate sources between jobs
  # (nightly_build_state.py); every other runner downloads them.
  export CMUX_NOTICES_CACHE="${CMUX_NEXT_NOTICES_CACHE:-$RUNNER_TEMP/cmux-notices}"
  ./scripts/cmux-next/generate-third-party-notices.sh --tui-source tree \
    --cargo-trees "$RUNNER_TEMP/cmux-notices-cargo-trees" --write-cargo-trees
fi
python3 scripts/ci/nightly_inputs.py bundle-notices build-universal/Build/Products/Release/cmux.app
