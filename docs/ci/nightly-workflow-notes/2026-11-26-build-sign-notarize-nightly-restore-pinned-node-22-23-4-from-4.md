# nightly.yml: job `build-sign-notarize-nightly`, step "Restore pinned Node 22.23.4 from the CI cache bucket"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Read-only: can this ASC key register nightly-next's own App ID
(com.cmuxterm.app.next) and fetch its Developer ID profile? It reports
and never writes or fails the build.
