# build-sign-notarize-nightly: SPARKLE_CHANNEL: ${{ needs.decide.outputs.track == 'nightly-next' && (vars.NIGHT

Where: the `build-sign-notarize-nightly` job in `.github/workflows/nightly.yml`, above `SPARKLE_CHANNEL: ${{ needs.decide.outputs.track == 'nightly-next' && (vars.NIGHTLY_NEXT_DEV_RING == …`.

cmux-next items carry a release-ring sparkle:channel, which only
cmux-next builds allow; every other build ignores them. With
NIGHTLY_NEXT_DEV_RING=on a new build starts on Dev (cmux-next-dev)
and moves to Nightly (cmux-next) on a canary pass
(scripts/ci/nightly_next_ring.py, nightly-next-verdict.yml).
