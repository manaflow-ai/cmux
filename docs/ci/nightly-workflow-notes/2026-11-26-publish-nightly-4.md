# 2026-11-26-publish-nightly-4

Above `run: if [ -f .publish-tooling/scripts/ci/gh_budget_wait.sh ]; then bash .publish-tooling/scripts/ci/gh_budget_wait.sh --install; fi` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

scripts/ci/gh_budget_wait.sh puts a gh first on PATH that waits for the shared budget's
reset (at most an hour per job, each wait logged) when a call is refused for the rate
limit, instead of failing the publish path. timeout-minutes leaves room for that hour.

## nightly.yml: job `publish-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Production secrets: GitHub releases them only to protected refs (the
environment's deployment branch policy: main, tags v*). The nightly-next
track uses `release-next`, whose policy allows only branch nightly-next.
