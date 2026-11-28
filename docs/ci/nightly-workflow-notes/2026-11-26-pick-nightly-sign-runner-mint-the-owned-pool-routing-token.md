# nightly.yml: job `pick-nightly-sign-runner`, step "Mint the owned-pool routing token"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

As cmux-next-dev-daily.yml: idle owned runners read live with the routing App's own
budget. Any failure leaves the token empty, and the pick below then finds no owned Mac.
