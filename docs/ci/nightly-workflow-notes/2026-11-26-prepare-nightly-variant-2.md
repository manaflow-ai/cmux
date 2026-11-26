# nightly.yml: job `prepare-nightly-variant`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Never skipped: a skipped fallback skips signing and publishing (runs 40154003204,
40155340212). After a primary success it finds that result and does nothing.
