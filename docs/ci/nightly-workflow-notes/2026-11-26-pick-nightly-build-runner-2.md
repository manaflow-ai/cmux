# 2026-11-26-pick-nightly-build-runner-2

Above `UNREAD_OWNED_FALLBACK: ${{ vars.CI_PR_POOL_OWNED == '1' && (vars.CI_OWNED_POOL_RESCUE || '1') != '0' && '1' || '' }}` (job `pick-nightly-build-runner`) in `.github/workflows/nightly.yml`.

Unread runners (a 403 on /actions/runners) still queue on the watched owned pool, which the
owned-pool rescue moves; only while the CI_PR_POOL_OWNED kill switch is on and the rescue itself is
(ci-owned-pool-rescue.yml runs only while CI_OWNED_POOL_RESCUE is not '0').
