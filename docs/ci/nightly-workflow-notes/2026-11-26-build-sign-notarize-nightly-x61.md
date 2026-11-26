# build-sign-notarize-nightly: &x61

Where: the `build-sign-notarize-nightly` job in `.github/workflows/nightly.yml`, above `- &x61`.

The signing keychain exists only while this job signs. It is deleted
before any step runs code from the bundle, and created again for the
DMG signature. scripts/ci/signing-keychain.sh owns its lifetime.
