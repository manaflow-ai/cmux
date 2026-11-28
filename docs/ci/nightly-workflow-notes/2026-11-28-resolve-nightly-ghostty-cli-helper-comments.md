# nightly.yml resolve-nightly-ghostty-cli-helper: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `resolve-nightly-ghostty-cli-helper:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-refresh-test-compilation-cache-1.md

Above `GH_TOKEN: ${{ secrets.NIGHTLY_HELPER_LOOKUP_TOKEN || github.token }}`:

    # Its own goblin App token first (leo-workspace machines/gh-app-roles.json push.actions_secrets
    # NIGHTLY_HELPER_LOOKUP_TOKEN), then github.token; a 403 waits to the limit's reset, at most 240 s a token.
