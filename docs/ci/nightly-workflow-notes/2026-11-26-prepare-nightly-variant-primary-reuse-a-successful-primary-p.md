# nightly.yml: job `prepare-nightly-variant-primary`, step "Reuse a successful primary preparation"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The fast build is already compiled arm64, but the downloaded cmux-tui
client can still be universal. Thin every non-universal artifact before
signing so the architecture gate remains meaningful. The Chromium
engine artifact is arm64 only: an x86_64 variant drops it first and
reports the browser unavailable.
