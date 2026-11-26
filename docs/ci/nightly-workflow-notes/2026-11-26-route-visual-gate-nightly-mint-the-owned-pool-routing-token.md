# nightly.yml: job `route-visual-gate-nightly`, step "Mint the owned-pool routing token"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Idle runners are read live, as side_lane_placement.py does. Any
failure leaves the token empty, and the gate is skipped.
