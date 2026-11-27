# nightly.yml: job `publish-nightly-next-github`, step "Take the release names lease"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The mutable state, only for the live feed's newest build. A failed write here leaves the immutable
assets above published and the job green (continue-on-error); the next build's run writes them.
One names writer at a time across runs, push or dispatch (the names job's group did this): its own
R2 lease (publish-lease.sh), which never cancels a waiter. Each write runs still-newest inside it.
