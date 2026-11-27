# nightly.yml: job `report-visual-gate-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The declared nightly-only mini is enabled after live admission is verified.
Keep the existing fallback; never reuse the stale builder-only placement.
