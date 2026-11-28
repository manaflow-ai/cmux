# nightly.yml pick-nightly-sign-runner: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `pick-nightly-sign-runner:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-2.md

Above `continue-on-error: true`:

    # A failed pick reads as success to the signing jobs, which then take the nightly pools.

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '`:

    # The picker has no signing key: the nightly-only pool (tests/test_nightly_owned_minis_only.py).

Above `environment:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-pick-nightly-sign-runner-4.md

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 137 || 17 }}`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-pick-nightly-sign-runner-2.md

Above `actions: read`:

    # The queue janitor's pool snapshot (an artifact).

Above `owned: ${{ github.repository == 'manaflow-ai/cmux' && github.ref_name == 'nightly-next' && github.ru`:

    # Why: docs/ci/nightly-workflow-notes.md#note-11

Above `sign_owned: ${{ (github.event_name == 'push' && github.run_attempt == 1 || steps.upload-marker.outco`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-pick-nightly-sign-runner-3.md

Above `sign_owned_pool: ${{ (github.event_name == 'push' && github.run_attempt == 1 || steps.upload-marker.`:

    # The shared pool label from sign_owned. Publication controls use this pool route so they never pin one runner.

Above `overtaken: ${{ steps.overtaken.outputs.overtaken }}`:

    # A newer run's build is already on the feed: build-sign-notarize-nightly skips.

Above `- name: Mint the glaeda read token`:

    # As pick-nightly-build-runner (run 41051244674's 403s were here).

Above `- name: Mint the owned-pool routing token`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-pick-nightly-sign-runner-mint-the-owned-pool-routing-token.md

Above `OWNED_LABELS: ${{ format('{0} {1}', vars.CI_NIGHTLY_NEXT_BUILD_RUNNER, vars.CI_SIDE_LANE_RUNNER) }}`:

    # In order; only labels ci-owned-pool-rescue.yml watches are offered.

Above `NIGHTLY_ONLY_LABEL: ${{ vars.CI_NIGHTLY_ONLY_RUNNER }}`:

    # Attempt 1 of a nightly-next push takes the all-nightly reservation with no runner read (nightly_build_runner.py).

Above `UNREAD_OWNED_FALLBACK: ${{ vars.CI_PR_POOL_OWNED == '1' && (vars.CI_OWNED_POOL_RESCUE || '1') != '0'`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-pick-nightly-sign-runner-pick-an-owned-mac-for-the-verify-jo.md

Above `- name: Pick a drained owned Mac for the signing jobs`:

    # Why: docs/ci/nightly-workflow-notes.md#note-41

Above `DRAIN_ANYWAY: "1"`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-pick-nightly-sign-runner-pick-a-drained-owned-mac-for-the-si.md

Above `SNAPSHOT_TOKEN: ${{ steps.snapshot-read-token.outputs.token || github.token }}`:

    # actions: read, to count the signing jobs already holding an owned Mac (at most one at once).
