# nightly.yml republish-nightly-deltas: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `- *hold-the-whole-mac`:

    # First, before any checkout or secret: the whole mini (glaeda's exclusive class), as the signing jobs.

Above `- *claim-publication-mac`:

    # Before any release App secret: the claim again, and a keychain a killed job left is removed.
