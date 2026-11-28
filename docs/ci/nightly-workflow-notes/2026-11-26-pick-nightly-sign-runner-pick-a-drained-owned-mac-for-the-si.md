# nightly.yml: job `pick-nightly-sign-runner`, step "Pick a drained owned Mac for the signing jobs"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Drain the mini that frees up soonest even past the 2 min horizon, never Blacksmith first
(signing_runner.py DRAIN_ANYWAY; Leo, 2026-10-30).
