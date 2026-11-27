# nightly.yml: job `build-sign-notarize-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Production secrets: GitHub releases them only to protected refs (the
environment's deployment branch policy: main, tags v*). The nightly-next
track uses `release-next`, whose policy allows only branch nightly-next.
