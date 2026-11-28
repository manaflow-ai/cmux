# nightly.yml sign-release-notes: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `sign-release-notes:`:

    # Why: docs/ci/nightly-workflow-notes.md#note-12

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64`:

    # Why: docs/ci/nightly-workflow-notes.md#note-50

Above `pull-requests: read`:

    # Read only: --pr-media reads the body of each highlight's pull request.

Above `PUBLISHED_SHA: ${{ needs.published-build.outputs.published_sha }}`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-sign-release-notes-2.md

Above `- *wait-through-github-api-rate-l`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-sign-release-notes-1.md

Above `env:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-sign-release-notes-fetch-the-commits-since-the-newest-publis.md

Above `GH_TOKEN: ${{ github.token }}`:

    # --pr-media: each highlight's picture from its pull request's body (read only).
