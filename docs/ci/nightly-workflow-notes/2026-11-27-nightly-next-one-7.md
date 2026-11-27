# 2026-11-27-nightly-next-one-7

Above `- name: Start the nearest deltas and the notes fetch (no key, no token)` (job `nightly-next-one`) in `.github/workflows/nightly.yml`.

The keyless deltas and the notes fetch run beside the bundle's checks; the key comes after a stray check.
With the deltas after the feed, the wait below holds the feed for the notes only. Why: docs/ci/nightly-workflow-notes.md#note-31
