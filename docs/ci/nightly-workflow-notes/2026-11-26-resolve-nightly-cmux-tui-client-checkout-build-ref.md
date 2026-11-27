# nightly.yml: job `resolve-nightly-cmux-tui-client`, step "Checkout build ref"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A reused checkout whose store makes git's pack-objects BUG() out (signal 6) fails every retry in place;
the next two steps drop that store and check out fresh. Leo, 2026-11-25: "are we able to decouple".
