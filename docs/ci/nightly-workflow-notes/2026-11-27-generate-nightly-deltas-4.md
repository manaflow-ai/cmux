# 2026-11-27-generate-nightly-deltas-4

Above `SPARKLE_CHANNEL: ${{ needs.published-build.outputs.track == 'nightly-next' && (vars.NIGHTLY_NEXT_DEV_RING == 'on' && 'cmux-next-dev' || 'cmux-next') || '' }}` (job `generate-nightly-deltas`) in `.github/workflows/nightly.yml`.

Every item starts on the new build's ring; republish-nightly-deltas
moves the ones whose canary passed back to Nightly.
