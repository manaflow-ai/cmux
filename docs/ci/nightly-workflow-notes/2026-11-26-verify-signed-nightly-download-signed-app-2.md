# nightly.yml: job `verify-signed-nightly`, step "Download signed app"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The post-sign checks of sign-cmux-bundle.sh (entitlements, helpers,
browser host) on this signed app whichever signer made it.
A build commit older than these checks has none to run.
