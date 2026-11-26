# nightly.yml: job `build-sign-notarize-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Sign and notarize on the same macOS 26 lane proven by stable releases.
actions:read lets the parallel artifact download resolve the blob URL.
