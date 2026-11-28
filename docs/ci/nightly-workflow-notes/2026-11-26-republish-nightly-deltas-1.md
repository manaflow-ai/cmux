# 2026-11-26-republish-nightly-deltas-1

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && needs.published-build.outputs.track == 'nightly-next' && 135 || needs.published-build.outputs.track == 'nightly-next' && 15 || 360 }}` (job `republish-nightly-deltas`) in `.github/workflows/nightly.yml`.

It holds the publish group, so a hang must not hold it for the default 6 h. nightly-next
makes no gh call here (deltas and feed go to R2) and took at most 1.3 minutes in 56 runs;
other tracks keep the default, as their release uploads may wait out the rate limit.
One-mini mode adds glaeda's capacity wait (tests/test_nightly_mini_gate_timeouts.py).
