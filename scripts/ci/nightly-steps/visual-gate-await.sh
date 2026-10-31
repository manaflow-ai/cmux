#!/usr/bin/env bash
# nightly.yml visual-gate-nightly-verdict: "Wait for the visual gate, at most 15 min in the queue". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
python3 scripts/ci/nightly_next_canary_mode.py await-gate --repo "$GITHUB_REPOSITORY" \
  --run-id "$GITHUB_RUN_ID" --attempt "$GITHUB_RUN_ATTEMPT" --job visual-gate-nightly \
  --queue-budget-minutes 15 --gate-timeout-minutes 75 | tee -a "$GITHUB_OUTPUT"
