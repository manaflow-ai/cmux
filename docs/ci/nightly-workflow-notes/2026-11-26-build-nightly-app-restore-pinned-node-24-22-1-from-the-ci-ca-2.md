# nightly.yml: job `build-nightly-app`, step "Restore pinned Node 24.22.1 from the CI cache bucket"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The webviews app's `vp build` must run on node: on bun it emits
different bytes (build-web-bundles.sh).
