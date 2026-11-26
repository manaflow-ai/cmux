# nightly.yml: job `publish-nightly-reel`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The nightly reel (scripts/cmux-next/media/reel.py): each pull request in this
build's signed notes with its tour's "after" clip and a title card, joined
into one video, and a page listing them, on the pr-media branch at
nightly-next/<build>/. Evidence only: no job needs this one, and it never
reports the nightly as failed.
