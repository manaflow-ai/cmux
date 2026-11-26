# publish-release-notes: publish-nightly-reel:

Where: the `publish-release-notes` job in `.github/workflows/nightly.yml`, above `publish-nightly-reel:`.

The nightly reel (scripts/cmux-next/media/reel.py): each pull request in this
build's signed notes with its tour's "after" clip and a title card, joined
into one video, and a page listing them, on the pr-media branch at
nightly-next/<build>/. Evidence only: no job needs this one, and it never
reports the nightly as failed.
