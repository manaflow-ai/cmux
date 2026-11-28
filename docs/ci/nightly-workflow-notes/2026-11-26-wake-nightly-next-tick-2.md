# 2026-11-26-wake-nightly-next-tick-2

Above `- name: Check the published feed offers deltas` (job `wake-nightly-next-tick`) in `.github/workflows/nightly.yml`.

The detector (hq#13299): the build this run published must reach the feed with its deltas, each
served at its length; a newer build already live passes with a notice. Red here names a feed
where every Mac downloads the full 243 MB DMG.
