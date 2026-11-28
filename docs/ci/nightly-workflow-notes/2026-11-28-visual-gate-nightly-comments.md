# nightly.yml visual-gate-nightly: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `environment: ${{ github.ref == 'refs/heads/main' && 'ci-cache-writer' || '' }}`:

    # A warm tour slot builds the DEV app in ~6-10 min; a cold one took 35 min.
    # The GhosttyKit download reads the R2 cache credentials: ci-cache-writer on main, no environment elsewhere.

Above `- name: Diff the states against the previous nightly`:

    # Warn only: states whose pixels changed since the previous nightly with no Visual-change line.

Above `- name: Hold publication`:

    # visual-gate-nightly-verdict reads this step's conclusion: it runs only when the gate holds the build.
