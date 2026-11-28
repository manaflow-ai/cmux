# nightly.yml pick-nightly-sign-runner: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `continue-on-error: true`:

    # A failed pick reads as success to the signing jobs, which then take the nightly pools.

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '`:

    # The picker has no signing key: the nightly-only pool (tests/test_nightly_owned_minis_only.py).

Above `actions: read`:

    # The queue janitor's pool snapshot (an artifact).

Above `sign_owned_pool: ${{ (github.event_name == 'push' && github.run_attempt == 1 || steps.upload-marker.`:

    # The shared pool label from sign_owned. Publication controls use this pool route so they never pin one runner.

Above `overtaken: ${{ steps.overtaken.outputs.overtaken }}`:

    # A newer run's build is already on the feed: build-sign-notarize-nightly skips.

Above `- name: Mint the glaeda read token`:

    # As pick-nightly-build-runner (run 41051244674's 403s were here).

Above `OWNED_LABELS: ${{ format('{0} {1}', vars.CI_NIGHTLY_NEXT_BUILD_RUNNER, vars.CI_SIDE_LANE_RUNNER) }}`:

    # In order; only labels ci-owned-pool-rescue.yml watches are offered.

Above `NIGHTLY_ONLY_LABEL: ${{ vars.CI_NIGHTLY_ONLY_RUNNER }}`:

    # Attempt 1 of a nightly-next push takes the all-nightly reservation with no runner read (nightly_build_runner.py).

Above `SNAPSHOT_TOKEN: ${{ steps.snapshot-read-token.outputs.token || github.token }}`:

    # actions: read, to count the signing jobs already holding an owned Mac (at most one at once).
