# nightly.yml runner-preflight: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `- name: Read the preflight without a git fetch`:

    # Leo's checkout-429 order, 0 github.com git fetches a nightly: the mirror, else the contents API (no git).
