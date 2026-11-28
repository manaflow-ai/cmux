# nightly.yml: job `build-sign-notarize-nightly`, step "Restore pinned Node 22.23.4 from the CI cache bucket"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Chromium on demand (plans/cmux-next/bundle-size-DESIGN.md 6.6): off
until the repository variable CMUX_NEXT_CEF_ON_DEMAND is 1.
