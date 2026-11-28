# nightly.yml: job `publish-nightly`, step "Download the language packs"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Languages download on first use (CMUX-570): the packs the app's pin names, from this run
(own or republished build) or the recovered build's run, published before the appcast.
