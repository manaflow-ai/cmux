# report-nightly-failure: close-nightly-failure-issue:

Where: the `report-nightly-failure` job in `.github/workflows/nightly.yml`, above `close-nightly-failure-issue:`.

The nightly-next feed alarm (one `nightly-next-feed-stale` issue past
NIGHTLY_NEXT_MAX_FEED_LAG_HOURS) runs from main every 30 minutes, so it also
sees promotion stalls: nightly-next-feed-watch.yml (cx-npz7g).
