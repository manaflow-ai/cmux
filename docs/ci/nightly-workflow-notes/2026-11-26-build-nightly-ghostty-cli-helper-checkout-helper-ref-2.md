# nightly.yml: job `build-nightly-ghostty-cli-helper`, step "Checkout helper ref"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

*select-xcode-sdk with the `if:` of this job's build steps (a resumed run builds nothing).
Zig only: no Xcode is selected here, so this is the SDK of the host's default Xcode.
