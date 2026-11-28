# nightly.yml: job `publish-release-notes`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Still publish-nightly's lock: the notes writes (notes/index.json and the
rest) have no compare-and-swap, so only that lock keeps an older build's
checked notes from landing after a newer publish. It is publish-nightly's
R2 lease, not a concurrency group: a group cancelled the older pending job
(run 41436891188). nightly-next only (if:), so no group at all.
