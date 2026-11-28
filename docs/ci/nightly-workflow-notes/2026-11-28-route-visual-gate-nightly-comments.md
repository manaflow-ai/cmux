# nightly.yml route-visual-gate-nightly: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '`:

    # Credentials stay on the validated ephemeral set until exclusive owned-Mac admission exists.

Above `environment:`:

    # GLAEDA_ROUTE_APP_KEY lives in the routing environment, like every other route job's.

Above `verdict: ${{ steps.pick.outputs.verdict }}`:

    # `unavailable` when no session runner was idle: the gate is skipped.
