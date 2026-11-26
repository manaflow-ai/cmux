# wake-nightly-next-tick: build-live-code-variant:

Where: the `wake-nightly-next-tick` job in `.github/workflows/nightly.yml`, above `build-live-code-variant:`.

Leo's live code variant (docs/cmux-next/live-code.md), after this run wrote the feed; continue-on-error, so the
nightly never waits on it or fails for it. NIGHTLY_NEXT_LIVE_CODE_VARIANT=off stops it. The build holds no secret.
