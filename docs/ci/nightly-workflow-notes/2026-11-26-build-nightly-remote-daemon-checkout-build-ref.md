# nightly.yml: job `build-nightly-remote-daemon`, step "Checkout build ref"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The exact Go of the shipped cmuxd-remote (its go.mod `toolchain` line);
build_remote_daemon_release_assets.sh refuses any other.
