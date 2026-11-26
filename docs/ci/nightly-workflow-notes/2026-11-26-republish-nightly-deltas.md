# nightly.yml `republish-nightly-deltas`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && needs.published-build.outputs.track == 'nightly-next' && 135 || needs`

It holds the publish group, so a hang must not hold it for the default 6 h. nightly-next
makes no gh call here (deltas and feed go to R2) and took at most 1.3 minutes in 56 runs;
other tracks keep the default, as their release uploads may wait out the rate limit.
One-mini mode adds glaeda's capacity wait (tests/test_nightly_mini_gate_timeouts.py).

## 2

Above: `run: bash .publish-tooling/scripts/ci/gh_budget_wait.sh --install`

scripts/ci/gh_budget_wait.sh puts a gh first on PATH that waits for the shared budget's
reset (at most an hour per job, each wait logged) when a call is refused for the rate
limit, instead of failing the publish path. timeout-minutes leaves room for that hour.

## 3

Above: `- name: Mint the release App token that reads the Dev ring switch`

The release App with every permission it has (Variables: read); the job's other App token
is contents-only. A failed mint leaves it empty, and the ring reads off.
