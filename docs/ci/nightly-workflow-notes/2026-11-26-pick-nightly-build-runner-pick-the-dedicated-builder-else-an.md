# nightly.yml: job `pick-nightly-build-runner`, step "Pick the dedicated builder, else an idle owned Mac, else a moving Blacksmith label"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Unread runners (a 403 on /actions/runners) still queue on the watched owned pool, which the
owned-pool rescue moves; only while the CI_PR_POOL_OWNED kill switch is on and the rescue itself is
(ci-owned-pool-rescue.yml runs only while CI_OWNED_POOL_RESCUE is not '0').
