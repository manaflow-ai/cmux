# 2026-11-27-build-sign-notarize-nightly-8

Above `- &x61` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

The signing keychain exists only while this job signs. It is deleted
before any step runs code from the bundle, and created again for the
DMG signature. scripts/ci/signing-keychain.sh owns its lifetime.
