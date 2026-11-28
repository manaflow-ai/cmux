# nightly.yml: job `build-nightly-deltas`, step "Select Xcode"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

BinaryDelta runs with the Xcode the keyed job selects; the script reads .xcode-version and the pins from
its own checkout (cone mode keeps the root files).
