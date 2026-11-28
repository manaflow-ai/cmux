# nightly.yml published-in: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `published-in:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-published-in-3.md

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-published-in-1.md

Above `timeout-minutes: 420`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-published-in-2.md

Above `env:`:

    # With the job token, for this step only: anonymous fetches got 403 four times (tail 45725593921).
