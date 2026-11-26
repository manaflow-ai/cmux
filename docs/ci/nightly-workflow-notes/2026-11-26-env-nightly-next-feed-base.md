# env: NIGHTLY_NEXT_FEED_BASE: https://files-next.cmux.com/nightly-next

Where: the `env` job in `.github/workflows/nightly.yml`, above `NIGHTLY_NEXT_FEED_BASE: https://files-next.cmux.com/nightly-next`.

The cmux-next track (branch `nightly-next`). The feed base must never be
main's nightly or RC feed; scripts/ci/nightly-next-guard.py refuses it.
The track's one feed: each build is signed once, as cmux NIGHTLY
(com.cmuxterm.app.nightly), the app the team runs (hq#7156; Leo,
2026-11-05: "THERE SHOULDN'T BE 2"). It keeps "/nightly-next/" in its
path: UpdateFeedResolver classifies the track by it. Release notes sit
beside it.
