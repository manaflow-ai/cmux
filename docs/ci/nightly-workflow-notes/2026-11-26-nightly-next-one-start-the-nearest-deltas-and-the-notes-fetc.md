# nightly.yml: job `nightly-next-one`, step "Start the nearest deltas and the notes fetch (no key, no token)"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The keyless deltas and the notes fetch run beside the bundle's checks; the key comes after a stray check.
With the deltas after the feed, the wait below holds the feed for the notes only. Why: docs/ci/nightly-workflow-notes.md#note-31
