# 2026-11-26-refresh-compilation-cache-1

Above `if: github.event_name == 'schedule' && github.event.schedule == '17 */6 * * *' && vars.CI_PR_POOL_OWNED != '1' || github.event_name == 'workflow_dispatch' && inputs.seed_only` (job `refresh-compilation-cache`) in `.github/workflows/nightly.yml`.

The schedule skips this cloud warmer while owned pools serve pull
requests (CI_PR_POOL_OWNED is 1). build-nightly-app saves the same key on
every published main push, so the remaining cloud readers (main's
full-suite dispatch, nightly's hosted fallback) restore at worst an
older entry by prefix. It runs on Blacksmith macOS, never a hosted Mac
(tests/test_ci_nightly_no_hosted_mac.py). A seed_only dispatch still warms it on demand.
