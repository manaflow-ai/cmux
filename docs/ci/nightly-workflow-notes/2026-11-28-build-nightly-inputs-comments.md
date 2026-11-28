# nightly.yml build-nightly-inputs: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `- &nightly-source-download`:

    # This run's pack of the build source (resolve-nightly-cmux-tui-client): 0 github.com fetches.
    # actions/checkout below runs only when it is missing. PREPARE_REUSED: prepare's reuse step found the app.
