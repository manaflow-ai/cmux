# nightly.yml: job `find-nightly-next-recovery`, step "Pick a drained owned Mac for the recovery jobs"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

As pick-nightly-sign-runner's sign-owned: a drained owned Mac, never Blacksmith. Any failure leaves it
empty and the recovery jobs take the signer's label.
