# wake-nightly-next-tick: Check the published feed offers deltas

Where: the `wake-nightly-next-tick` job in `.github/workflows/nightly.yml`, above `- name: Check the published feed offers deltas`.

The detector (hq#13299): the build this run published must reach the feed with its deltas, each
served at its length; a newer build already live passes with a notice. Red here names a feed
where every Mac downloads the full 243 MB DMG.
