# nightly.yml decide: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '`:

    # Routing bootstrap: nothing places it first, so it takes the nightly-only pool (glaeda's light class).

Above `- name: Check out the NEXT decision helper`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-decide-check-out-the-next-decision-helper.md

Above `- name: Mint a spare read token for decide`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-decide-1.md

Above `- name: Shadow the app-input digest`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-decide-shadow-the-app-input-digest.md
