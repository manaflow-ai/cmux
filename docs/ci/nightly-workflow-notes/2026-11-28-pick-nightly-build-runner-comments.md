# nightly.yml pick-nightly-build-runner: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '`:

    # It reads the routing App key, so it stays on the nightly-only pool, whose minis run only nightly.yml.

Above `- name: Mint the owned-pool routing token`:

    # The all-nightly route reads runners only to offer its warm builder (CI_NIGHTLY_ONLY_BUILDER_RUNNER).

Above `NIGHTLY_ONLY_LABEL: ${{ vars.CI_NIGHTLY_ONLY_RUNNER }}`:

    # Enabled only after the all-nightly managed runner is enrolled.

Above `NIGHTLY_ONLY_BUILDER_LABEL: ${{ vars.CI_NIGHTLY_ONLY_BUILDER_RUNNER }}`:

    # build-nightly-app's warm runner per dedicated Mac, offered only while one is idle; unset keeps the plain label.

Above `DEDICATED_LABEL: ${{ vars.CI_NIGHTLY_NEXT_DEDICATED_LABEL }}`:

    # The older builder-only reservation remains an independent fallback.

Above `OWNED_LABELS: ${{ format('{0} {1}', vars.CI_NIGHTLY_NEXT_BUILD_RUNNER, vars.CI_SIDE_LANE_RUNNER) }}`:

    # In order; only labels ci-owned-pool-rescue.yml watches are offered.
