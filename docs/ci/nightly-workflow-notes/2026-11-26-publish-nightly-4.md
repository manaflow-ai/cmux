# 2026-11-26-publish-nightly-4

Above `run: if [ -f .publish-tooling/scripts/ci/gh_budget_wait.sh ]; then bash .publish-tooling/scripts/ci/gh_budget_wait.sh --install; fi` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

scripts/ci/gh_budget_wait.sh puts a gh first on PATH that waits for the shared budget's
reset (at most an hour per job, each wait logged) when a call is refused for the rate
limit, instead of failing the publish path. timeout-minutes leaves room for that hour.
