# 2026-11-27-republish-nightly-deltas-2

Above `continue-on-error: true` (job `republish-nightly-deltas`) in `.github/workflows/nightly.yml`.

Optional, as generate-nightly-deltas: the full DMG is already on the feed, so a missing or failed delta
never fails the run.
