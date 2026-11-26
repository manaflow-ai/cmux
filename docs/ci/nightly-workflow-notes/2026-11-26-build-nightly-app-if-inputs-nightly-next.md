# build-nightly-app: if: inputs.nightly_next_unsigned_run == ''

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `if: inputs.nightly_next_unsigned_run == ''`.

scripts/ci/gh_budget_wait.sh puts a gh first on PATH that waits for the shared budget's
reset (at most an hour per job, each wait logged) when a call is refused for the rate
limit, instead of failing the publish path. timeout-minutes leaves room for that hour.
