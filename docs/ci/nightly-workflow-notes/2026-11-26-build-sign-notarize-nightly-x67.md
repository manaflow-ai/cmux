# build-sign-notarize-nightly: &x67

Where: the `build-sign-notarize-nightly` job in `.github/workflows/nightly.yml`, above `- &x67`.

The DMG needs the identity again. It runs no bundle code; notarize-nightly-dmg.sh deletes the keychain right after
the DMG signature, before static artifact verification.
