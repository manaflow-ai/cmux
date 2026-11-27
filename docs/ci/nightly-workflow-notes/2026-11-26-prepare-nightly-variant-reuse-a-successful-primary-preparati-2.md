# nightly.yml: job `prepare-nightly-variant`, step "Reuse a successful primary preparation"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The Ghostty dependency license tree (collect-ghostty-licenses.py, checked
by verify-ghostty-license-bundle.py) ships in the app, with the MPL-2.0
source offer that names this release's cmux-next source archive and tag.
