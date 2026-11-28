# nightly.yml: job `publish-nightly`, step "Mint release tag app token"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The release App (Contents + Workflows write only); its id and key
live only in the release and release-next environments.
