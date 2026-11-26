# publish-nightly: Download verified DMG digests

Where: the `publish-nightly` job in `.github/workflows/nightly.yml`, above `- name: Download verified DMG digests`.

Publish only the bytes that a job without secrets verified:
verify-final-dmg-nightly for this run's build, verify-recovered-nightly-next
for a continued one.
