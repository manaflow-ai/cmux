# 2026-11-26-republish-nightly-deltas-2

Above `run: bash .publish-tooling/scripts/ci/gh_budget_wait.sh --install` (job `republish-nightly-deltas`) in `.github/workflows/nightly.yml`.

scripts/ci/gh_budget_wait.sh puts a gh first on PATH that waits for the shared budget's
reset (at most an hour per job, each wait logged) when a call is refused for the rate
limit, instead of failing the publish path. timeout-minutes leaves room for that hour.

## nightly.yml: job `republish-nightly-deltas`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Optional, as generate-nightly-deltas: the full DMG is already on the feed, so a missing or failed delta
never fails the run.
