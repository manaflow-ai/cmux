# 2026-11-27-verify-signed-nightly-3

Above `- &x77` (job `verify-signed-nightly`) in `.github/workflows/nightly.yml`.

The post-sign checks of sign-cmux-bundle.sh (entitlements, helpers,
browser host) on this signed app whichever signer made it.
A build commit older than these checks has none to run.
