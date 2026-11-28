# nightly.yml keep-published-dsyms: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `keep-published-dsyms:`:

    # Why: docs/ci/nightly-workflow-notes.md#note-25

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 195 || 75 }}`:

    # One-mini mode adds glaeda's capacity wait (tests/test_nightly_mini_gate_timeouts.py).

Above `- name: Download the published build's dSYMs from the run that compiled it (parallel)`:

    # Why: docs/ci/nightly-workflow-notes.md#note-8

Above `timeout-minutes: 65`:

    # Off the publish path: waits up to an hour for github.token's reset when every spare is spent or dead (run 46125411693).

Above `GH_TOKEN_SPARES: ${{ secrets.CI_POOL_TOKEN_1 }} ${{ secrets.CI_POOL_TOKEN_2 }}`:

    # Spent hour: download-run-artifact.py moves to a CI pool's token at once (run 45823496118).
