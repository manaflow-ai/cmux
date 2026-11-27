# 2026-11-27-wake-nightly-next-tick-1

Above `build-live-code-variant:` (job `wake-nightly-next-tick`) in `.github/workflows/nightly.yml`.

Leo's live code variant (docs/cmux-next/live-code.md), after this run wrote the feed; continue-on-error, so the
nightly never waits on it or fails for it. NIGHTLY_NEXT_LIVE_CODE_VARIANT=off stops it. The build holds no secret.
