# run-name: on:

Where: the `run-name` job in `.github/workflows/nightly.yml`, above `on:`.

Publish channels, resolved once in `decide`: `main` publishes cmux NIGHTLY, `rc/**` cmux RC,
`nightly-next` the cmux-next track (own release, Sparkle key and feed, signed as cmux
NIGHTLY; hq#7156), each feed advancing only in its channel. Only main's
promote-nightly-next moves `nightly-next` (release-next environment).
