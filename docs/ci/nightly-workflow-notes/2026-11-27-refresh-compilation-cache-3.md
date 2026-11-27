# 2026-11-27-refresh-compilation-cache-3

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 210 || 90 }}` (job `refresh-compilation-cache`) in `.github/workflows/nightly.yml`.

This job rebuilds the cache after the store drops it, so it runs cold
by design; scheduled run 35134963192 was cancelled at 45 minutes.
