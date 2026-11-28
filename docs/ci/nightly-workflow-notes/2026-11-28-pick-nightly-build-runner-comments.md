# `pick-nightly-build-runner`: the comments that were inline

Moved out of `.github/workflows/nightly.yml` on 2026-11-28 to keep the file under the size guard
(tests/test_ci_workflow_file_size.py). Each note names the line it sat above.

- Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY`: It reads the routing App key, so it stays on the nightly-only pool, whose minis run only nightly.yml.
- Above `- name: Mint the owned-pool routing token`: The all-nightly route reads runners only to offer its warm builder (CI_NIGHTLY_ONLY_BUILDER_RUNNER).
- Above `NIGHTLY_ONLY_LABEL: ${{ vars.CI_NIGHTLY_ONLY_RUNNER }}`: Enabled only after the all-nightly managed runner is enrolled.
- Above `NIGHTLY_ONLY_BUILDER_LABEL: ${{ vars.CI_NIGHTLY_ONLY_BUILDER_RUNNER }}`: build-nightly-app's warm runner per dedicated Mac, offered only while one is idle; unset keeps the plain label.
- Above `DEDICATED_LABEL: ${{ vars.CI_NIGHTLY_NEXT_DEDICATED_LABEL }}`: The older builder-only reservation remains an independent fallback.
- Above `OWNED_LABELS: ${{ format('{0} {1}', vars.CI_NIGHTLY_NEXT_BUILD_RUNNER, vars.CI_SIDE_LANE_RUNNER) }}`: In order; only labels ci-owned-pool-rescue.yml watches are offered.
