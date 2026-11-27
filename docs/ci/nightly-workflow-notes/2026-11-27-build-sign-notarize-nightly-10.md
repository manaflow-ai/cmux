# 2026-11-27-build-sign-notarize-nightly-10

Above `- &x67` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

The DMG needs the identity again. It runs no bundle code; notarize-nightly-dmg.sh deletes the keychain right after
the DMG signature, before static artifact verification.
