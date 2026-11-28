# nightly.yml publish-release-notes: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `timeout-minutes: 130`:

    # 70 for the work (an hour of it for API rate-limit waits) plus the lease's 60-minute wait.

Above `- *github-token-for-git`:

    # scripts/ci only: a full checkout stalled on the JIT VM (tails 45689720464, 45679817194).

Above `- name: Take the nightly-next publish lease`:

    # publish-nightly's lease (its key, TTL and wait), before the publication head is read.
