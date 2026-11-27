# 2026-11-27-build-sign-notarize-nightly-16

Above `CMUX_DEFER_LAUNCH_SMOKES: "true"` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

Runtime checks for the stapled app and final DMG run in
verify-signed-nightly, a job without secrets.
