# nightly.yml: job `wake-nightly-next-tick`, step "Check the published feed offers deltas"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The detector (hq#13299): the build this run published must reach the feed with its deltas, each
served at its length; a newer build already live passes with a notice. Red here names a feed
where every Mac downloads the full 243 MB DMG.
