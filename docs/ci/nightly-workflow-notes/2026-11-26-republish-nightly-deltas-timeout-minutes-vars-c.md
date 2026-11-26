# republish-nightly-deltas: timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && needs.published-build.outputs

Where: the `republish-nightly-deltas` job in `.github/workflows/nightly.yml`, above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && needs.published-build.outputs.track == 'nightly-n…`.

It holds the publish group, so a hang must not hold it for the default 6 h. nightly-next
makes no gh call here (deltas and feed go to R2) and took at most 1.3 minutes in 56 runs;
other tracks keep the default, as their release uploads may wait out the rate limit.
One-mini mode adds glaeda's capacity wait (tests/test_nightly_mini_gate_timeouts.py).
