# nightly.yml early-nightly-webviews: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-linux' }}`:

    # check-nightly-webviews' route: no secret, never a Mac.

Above `continue-on-error: ${{ vars.NIGHTLY_COMPONENT_GATES != 'block' }}`:

    # Leo, 2026-11-25: "are we able to decouple". A red here is a report; the nightly still publishes.
