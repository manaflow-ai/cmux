# nightly.yml: job `generate-nightly-deltas`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Only scripts/ (and, by cone mode, the root .xcode-version) is read from it, so it is sparse: a full
clone took 96 s of the whole-Mac hold (run 42033609306, 14:11:49-14:13:25Z).
