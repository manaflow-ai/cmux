# nightly.yml republish-nightly-deltas: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `needs: [published-build, generate-nightly-deltas, pick-nightly-sign-runner]`:

    # Why: docs/ci/nightly-workflow-notes.md#note-5

Above `continue-on-error: true`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-republish-nightly-deltas-2.md

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.ref != 'refs/heads`:

    # Why: docs/ci/nightly-workflow-notes.md#note-47

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && needs.published-build.outputs.track == 'nightly-n`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-republish-nightly-deltas-1.md

Above `- *hold-the-whole-mac`:

    # First, before any checkout or secret: the whole mini (glaeda's exclusive class), as the signing jobs.

Above `- *claim-publication-mac`:

    # Before any release App secret: the claim again, and a keychain a killed job left is removed.

Above `run: bash .publish-tooling/scripts/ci/gh_budget_wait.sh --install`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-republish-nightly-deltas-2.md

Above `- name: Mint the release App token that reads the Dev ring switch`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-republish-nightly-deltas-mint-the-release-app-token-that-rea.md
