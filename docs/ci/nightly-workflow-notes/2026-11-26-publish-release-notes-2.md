# 2026-11-26-publish-release-notes-2

Above `publish-nightly-reel:` (job `publish-release-notes`) in `.github/workflows/nightly.yml`.

The nightly reel (scripts/cmux-next/media/reel.py): each pull request in this
build's signed notes with its tour's "after" clip and a title card, joined
into one video, and a page listing them, on the pr-media branch at
nightly-next/<build>/. Evidence only: no job needs this one, and it never
reports the nightly as failed.
