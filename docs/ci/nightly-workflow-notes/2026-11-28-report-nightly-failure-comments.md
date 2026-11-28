# nightly.yml report-nightly-failure: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `actions: read`:

    # The replaced-build check lists this run's jobs.

Above `HEAD_SHA: ${{ needs.resolve-nightly-cmux-tui-client.outputs.build_sha || needs.published-build.outpu`:

    # In the dispatched run, decide and the build jobs skipped: the record names the build.

Above `TIP_SHA: ${{ needs.decide.outputs.head_sha || needs.published-build.outputs.head_sha }}`:

    # The pushed nightly-next head (HEAD_SHA can be an older resolved build commit).
