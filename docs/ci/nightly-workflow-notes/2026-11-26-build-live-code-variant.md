# nightly.yml: job `build-live-code-variant`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Leo's live code variant (docs/cmux-next/live-code.md), after this run wrote the feed; continue-on-error, so the
nightly never waits on it or fails for it. NIGHTLY_NEXT_LIVE_CODE_VARIANT=off stops it. The build holds no secret.
