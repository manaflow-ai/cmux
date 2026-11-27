# 2026-11-27-verify-signed-nightly-1

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_MINI || needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && needs.pick-nightly-sign-runner.outputs.owned || vars.CI_NIGHTLY_NEXT_BUILD_RUNNER || 'glaeda-nightly-std-xcode-26.6' }}` (job `verify-signed-nightly`) in `.github/workflows/nightly.yml`.

A failed-jobs rerun retains an older picker. Rejoin the fleet pool, never
that old runner choice, once; later attempts use the Blacksmith overflow.
