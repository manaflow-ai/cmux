# nightly.yml promote-nightly-next: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `promote-nightly-next:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-25-promote-nightly-next.md

Above `environment: nightly-next-promote`:

    # Holds only the release App credentials (CMUX_RELEASE_APP_*).

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-promote-nightly-next-1.md

Above `- &hold-the-whole-mac`:

    # First, before any checkout or secret: the whole mini (glaeda's exclusive class), as the signing jobs.

Above `- &claim-root-checkout-mac`:

    # Before the release App secret: the claim again, and a keychain a killed job left is removed.

Above `if: (steps.decide.outputs.action == 'promote' || steps.decide.outputs.action == 'needs-ack') && step`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-promote-nightly-next-mint-release-app-token.md
