# nightly.yml: job `find-nightly-next-recovery`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The owned pick mints the routing token (GLAEDA_ROUTE_APP_KEY), so the key is read in the
routing environment, as pick-nightly-sign-runner does.
