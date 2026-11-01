#!/usr/bin/env bash
# nightly.yml visual-gate-nightly-verdict: "Fail with the gate when it holds the build". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# A held build fails this job too, so "Re-run failed jobs" retries it with the gate.
set -e  # the inline step ran under bash -e
echo "::error title=nightly-next visual gate::this run's build is held; re-run failed jobs to retry the gate and this verdict together"
exit 1
