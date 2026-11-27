# nightly.yml: job `build-nightly-app`, step "Install Zig for fast cmux-tui client"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A fast branch dogfood build only needs the arm64 client that is bundled
in this macOS app. Building it here avoids waiting for the full
cross-platform R2 artifact matrix. Main and release keep the immutable
manifest path below, so their machine and distribution artifacts stay
complete.
