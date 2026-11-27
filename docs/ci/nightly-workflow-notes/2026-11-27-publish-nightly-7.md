# 2026-11-27-publish-nightly-7

Above `- name: Download verified DMG digests` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

Publish only the bytes that a job without secrets verified:
verify-final-dmg-nightly for this run's build, verify-recovered-nightly-next
for a continued one.
