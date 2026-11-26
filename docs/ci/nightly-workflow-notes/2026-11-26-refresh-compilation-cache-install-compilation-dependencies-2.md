# nightly.yml: job `refresh-compilation-cache`, step "Install compilation dependencies"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A GitHub download stores the pinned archive in the CI cache bucket, which
download-prebuilt-ghosttykit.sh reads when GitHub refuses (2026-11-26 403s).
