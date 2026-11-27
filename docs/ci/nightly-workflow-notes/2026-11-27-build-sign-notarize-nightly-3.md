# 2026-11-27-build-sign-notarize-nightly-3

Above `permissions:` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

Sign and notarize on the same macOS 26 lane proven by stable releases.
actions:read lets the parallel artifact download resolve the blob URL.
