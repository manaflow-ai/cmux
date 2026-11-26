# nightly.yml: job `build-nightly-app`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

One build slot per run: a newer push builds beside an older one and never
replaces it (a shared slot evicted waiting builds, 2026-10-19). publish-nightly's
recheck refuses a build no newer than both feeds.
