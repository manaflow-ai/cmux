# 2026-11-27-pick-nightly-sign-runner-5

Above `UNREAD_OWNED_FALLBACK: ${{ vars.CI_PR_POOL_OWNED == '1' && (vars.CI_OWNED_POOL_RESCUE || '1') != '0' && '1' || '' }}` (job `pick-nightly-sign-runner`) in `.github/workflows/nightly.yml`.

As the build pick: unread runners (run 41335987427's 403 rate limit on the routing App) queue the
verify jobs on the watched owned pool, not blind on Blacksmith macOS.
