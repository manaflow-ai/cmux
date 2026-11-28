# 2026-11-26-publish-release-notes-2

Above `publish-nightly-reel:` (job `publish-release-notes`) in `.github/workflows/nightly.yml`.

The nightly reel (scripts/cmux-next/media/reel.py): each pull request in this
build's signed notes with its tour's "after" clip and a title card, joined
into one video, and a page listing them, on the pr-media branch at
nightly-next/<build>/. Evidence only: no job needs this one, and it never
reports the nightly as failed.

## nightly.yml: job `publish-release-notes`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A one-job JIT VM on purpose, in the tail only (after sign-release-notes): up to 130 min of lease and rate-limit
waits would hold the whole signing Mac (test_nightly_owned_minis_only.HOSTED_TAIL_JOBS).
