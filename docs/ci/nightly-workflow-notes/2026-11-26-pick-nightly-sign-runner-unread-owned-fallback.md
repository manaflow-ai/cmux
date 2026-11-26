# pick-nightly-sign-runner: UNREAD_OWNED_FALLBACK: ${{ vars.CI_PR_POOL_OWNED == '1' && (vars.CI_OWNED_POOL_R

Where: the `pick-nightly-sign-runner` job in `.github/workflows/nightly.yml`, above `UNREAD_OWNED_FALLBACK: ${{ vars.CI_PR_POOL_OWNED == '1' && (vars.CI_OWNED_POOL_RESCUE || '1') != '0'…`.

As the build pick: unread runners (run 41335987427's 403 rate limit on the routing App) queue the
verify jobs on the watched owned pool, not blind on Blacksmith macOS.
