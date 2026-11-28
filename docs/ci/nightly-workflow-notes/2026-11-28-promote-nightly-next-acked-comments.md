# nightly.yml promote-nightly-next-acked: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `promote-nightly-next-acked:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-promote-nightly-next-acked-2.md

Above `if: false`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-promote-nightly-next-acked.md

Above `environment: nightly-next-promote`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-promote-nightly-next-acked-4.md

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '`:

    # Retired (if: false). Should it run again: promote-nightly-next's route and the whole Mac, never GitHub-hosted.

Above `concurrency:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-promote-nightly-next-acked-3.md

Above `- *hold-the-whole-mac`:

    # First, before any checkout or secret: the whole mini (glaeda's exclusive class), as the signing jobs.
