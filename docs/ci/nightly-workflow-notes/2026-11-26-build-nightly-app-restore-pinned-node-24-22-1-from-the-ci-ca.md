# nightly.yml: job `build-nightly-app`, step "Restore pinned Node 24.22.1 from the CI cache bucket"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

build-nightly-inputs can start after this step (run 41570134320 queued it 7.6 min, so the
bundles built here for 106 s); feat-cmux-next's pushes publish them to R2 by source key.
