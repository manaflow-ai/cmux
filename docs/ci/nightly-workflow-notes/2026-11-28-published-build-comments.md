# nightly.yml published-build: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `timeout-minutes: 70`:

    # Room for gh_budget_wait.sh's wait through a rate limit: tail run 45925996466 failed its one gh read on
    # "API rate limit exceeded for installation" (HTTP 403), so build 4592220755201 shipped with no release notes.

Above `GH_TOKEN_SPARES: ${{ secrets.CI_POOL_TOKEN_1 }} ${{ secrets.CI_POOL_TOKEN_2 }}`:

    # A second path for every gh call (c-bedbdb1917): a refused github.token hour moves to a CI pool's own
    # hour at once (gh_budget_wait.sh); a write the read-only pool cannot do goes back and waits as before.

Above `- name: Download its record`:

    # gh run download, not actions/download-artifact: its artifact list and zip reads go through the same wrapper.
