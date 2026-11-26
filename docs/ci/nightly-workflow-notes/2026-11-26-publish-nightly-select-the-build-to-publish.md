# nightly.yml: job `publish-nightly`, step "Select the build to publish"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Chromium on demand and the source offer: the switches as they are now, except that a
republished build publishes the pack its source signed with (the app's pin names it), and
no source archive when its source made none.
