# nightly.yml: job `verify-signed-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A failed-jobs rerun retains an older picker. Rejoin the fleet pool, never
that old runner choice, once; later attempts use the Blacksmith overflow.
