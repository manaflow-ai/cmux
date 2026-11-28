# nightly.yml publish-nightly-next-github: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `publish-nightly-next-github:`:

    # Why: docs/ci/nightly-workflow-notes.md#note-21

Above `environment: ${{ github.ref == 'refs/heads/nightly-next' && 'release-next' || 'release' }}`:

    # Nothing on the feed's path needs this job, so a failure shows red and holds nothing.

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-next-github.md

Above `timeout-minutes: 240`:

    # The two former jobs' limits added up: the uploads and the names each may wait out an hour of rate limits.

Above `- *github-token-for-git`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-27-publish-nightly-next-github-2.md

Above `run-id: ${{ needs.published-build.outputs.source_run || github.run_id }}`:

    # From the run that published (the dispatched run's published-build names it).

Above `run-id: ${{ needs.published-build.outputs.source_run || github.run_id }}`:

    # From the run that published (the dispatched run's published-build names it).

Above `run-id: ${{ needs.published-build.outputs.source_run || github.run_id }}`:

    # From the run that published (the dispatched run's published-build names it).

Above `run-id: ${{ needs.published-build.outputs.source_run || github.run_id }}`:

    # From the run that published (the dispatched run's published-build names it).

Above `run-id: ${{ needs.published-build.outputs.source_run || github.run_id }}`:

    # From the run that published (the dispatched run's published-build names it).

Above `- name: Take the recovered build's source archive`:

    # Why: docs/ci/nightly-workflow-notes.md#note-46

Above `- name: Take the release names lease`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-next-github-1.md

Above `LEASE_MAX_HOLD: 10800`:

    # The names writes may wait out an hour of rate limits, as the job's timeout allows.
