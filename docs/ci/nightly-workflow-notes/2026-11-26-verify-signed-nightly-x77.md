# verify-signed-nightly: &x77

Where: the `verify-signed-nightly` job in `.github/workflows/nightly.yml`, above `- &x77`.

The post-sign checks of sign-cmux-bundle.sh (entitlements, helpers,
browser host) on this signed app whichever signer made it.
A build commit older than these checks has none to run.
