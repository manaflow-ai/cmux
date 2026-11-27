# 2026-11-27-build-sign-notarize-nightly-11

Above `- name: Download the cmux-next source archive for recovery` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

A later run publishes this build from the recovery artifact alone, so
it also carries the SSH daemon assets and, when published, the source
archive (their own artifacts expire after 3 days).
