#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Finish the dSYM upload to Sentry". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -uo pipefail
state="$RUNNER_TEMP/sentry-dsyms"
[ -p "$state/status.fifo" ] || { echo "the dSYM upload to Sentry was never started" >&2; exit 1; }
status=""
read -r status <"$state/status.fifo" || true
cat "$state/upload.log"
rm -rf "$state"
[ "$status" = 0 ] || { echo "the dSYM upload to Sentry failed (status ${status:-none})" >&2; exit 1; }
