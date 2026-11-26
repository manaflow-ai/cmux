# build-sign-notarize-nightly: SPARKLE_MINIMUM_SYSTEM_VERSION="$(python3 scripts/ci/appcast_minimum_system_vers

Where: the `build-sign-notarize-nightly` job in `.github/workflows/nightly.yml`, above `SPARKLE_MINIMUM_SYSTEM_VERSION="$(python3 scripts/ci/appcast_minimum_system_version.py floor "$CHANN…`.

The new item carries the bundle's macOS floor (14.0 for cmux-next since 2026-10-13),
so older macOS keeps the previous (legacy) items still in the feed.
