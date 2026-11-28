# nightly.yml retry-nightly-next: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `retry-nightly-next:`:

    # Why: docs/ci/nightly-workflow-notes.md#note-24

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 190 || 70 }}`:

    # Room for gh_budget_wait.sh's wait through a rate limit, and for glaeda's capacity wait on the mini.

Above `issues: write`:

    # Retry exhaustion comments on the nightly-next-feed-stale issue (nightly_next_retry_exhausted.py).

Above `- name: Read scripts/ci from the host's git mirror`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-27-retry-nightly-next-1.md
