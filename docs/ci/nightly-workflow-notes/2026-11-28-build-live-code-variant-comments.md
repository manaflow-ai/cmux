# nightly.yml build-live-code-variant: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `outputs:`:

    # continue-on-error makes this job's result success even when it failed: sign gates on built, not the result.
