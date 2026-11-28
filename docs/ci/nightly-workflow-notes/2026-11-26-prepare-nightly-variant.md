# nightly.yml: job `prepare-nightly-variant`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The fallback preparation, and the preparation result every later job reads
(needs.prepare-nightly-variant): success after a primary success (a no-op leg) or after
its own preparation. Until 2026-10-31 a separate prepare-nightly-variant job only echoed
that result, one more queued hop on the signing path (4.8 min queued for a 0 s job in
run 41187578702 attempt 2).
