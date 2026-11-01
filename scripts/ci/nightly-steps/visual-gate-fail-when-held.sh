#!/usr/bin/env bash
# nightly.yml visual-gate-nightly-verdict: "Record a failed advisory verdict". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# A failing enforce-mode verdict fails this advisory job too, so "Re-run failed
# jobs" retries it with the gate.
set -e  # the inline step ran under bash -e
echo "::error title=nightly-next visual gate::the advisory verdict failed; re-run failed jobs to retry the gate and this verdict together"
exit 1
