#!/usr/bin/env bash
# nightly.yml visual-gate-nightly-verdict: "Wait for the visual gate, at most 10 min past the signed build". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
#
# On attempt 1 this job starts only once the signed build is ready (it needs
# verify-final-dmg-nightly), so the gate has had the whole build to start. The
# budgets run from when that check finished (--since-job, GitHub's own
# timestamps), so this job's own queue time counts too. A gate still queued
# 5 minutes after it lost its runner is reported as unavailable; a gate gets
# at most 10 minutes in all, so advisory coverage remains bounded without
# affecting publication.
#
# A re-run ("Re-run failed jobs" after the advisory verdict failed) starts the
# gate and this job together, so the gate gets its whole queue budget and timeout.
#
# Outside enforce mode no verdict fails the advisory job, so nothing is waited for.
set -euo pipefail
if [ "${GITHUB_RUN_ATTEMPT:-1}" = 1 ]; then
  budget=(--queue-budget-minutes 5 --hold-minutes 10 --since-job "Verify final nightly DMG")
else
  budget=(--queue-budget-minutes 15 --gate-timeout-minutes 75)
fi
python3 scripts/ci/nightly_next_canary_mode.py await-gate --repo "$GITHUB_REPOSITORY" \
  --run-id "$GITHUB_RUN_ID" --attempt "$GITHUB_RUN_ATTEMPT" --job visual-gate-nightly \
  --mode "${GATE_MODE:-}" "${budget[@]}" | tee -a "$GITHUB_OUTPUT"
