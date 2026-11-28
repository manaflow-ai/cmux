# nightly.yml publish-nightly-reel: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `publish-nightly-reel:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-release-notes-2.md

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-reel-3.md

Above `environment: pr-media`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-reel-4.md

Above `permissions:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-reel-1.md
