# 2026-11-26-build-nightly-app-2

Above `if: inputs.nightly_next_unsigned_run == ''` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

scripts/ci/gh_budget_wait.sh puts a gh first on PATH that waits for the shared budget's
reset (at most an hour per job, each wait logged) when a call is refused for the rate
limit, instead of failing the publish path. timeout-minutes leaves room for that hour.
