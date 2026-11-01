#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Build the cmux-next iPhone host (cmux-mobile-host)". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
hostd_bin="$RUNNER_TEMP/cmux-next-mobile-host/cmux-mobile-host"
python3 scripts/ci/background_build.py start --state "$RUNNER_TEMP/nightly-helper-builds" mobile-host -- \
  nice -n 10 env CMUX_NEXT_MOBILE_HOST_ARCHS="$NIGHTLY_COMPILE_ARCHS" scripts/cmux-next/build-mobile-host.sh --output "$hostd_bin"
echo "CMUX_NEXT_MOBILE_HOST_PENDING_BIN=$hostd_bin" >> "$GITHUB_ENV"
