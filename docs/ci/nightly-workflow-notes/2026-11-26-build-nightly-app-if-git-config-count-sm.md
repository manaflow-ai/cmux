# build-nightly-app: if GIT_CONFIG_COUNT=$sm_unmapped git -c protocol.https.allow=never -c core.hooks

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `if GIT_CONFIG_COUNT=$sm_unmapped git -c protocol.https.allow=never -c core.hooksPath=/dev/null submo…`.

A warm slot holds the submodule commits already: check them out with no network (https refused, so
a missing one fails here instead of cloning anonymously), then fetch only with the App's token.
Without the mirror rewrite: a clone from a mirror here skips its refs/pins and leaves no HEAD.
