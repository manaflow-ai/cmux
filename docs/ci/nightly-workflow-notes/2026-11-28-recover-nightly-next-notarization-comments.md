# nightly.yml recover-nightly-next-notarization: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `- name: Claim the whole Mac for signing`:

    # Before any secret: the same check again, and a signing keychain a killed job left is removed.
