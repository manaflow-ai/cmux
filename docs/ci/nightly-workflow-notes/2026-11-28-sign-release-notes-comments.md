# nightly.yml sign-release-notes: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `pull-requests: read`:

    # Read only: --pr-media reads the body of each highlight's pull request.

Above `GH_TOKEN: ${{ github.token }}`:

    # --pr-media: each highlight's picture from its pull request's body (read only).
