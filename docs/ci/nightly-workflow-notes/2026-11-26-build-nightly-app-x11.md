# build-nightly-app: &x11

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `- &x11`.

A persistent owned mini keeps the workspace between jobs. Checkout's
clean drops untracked output; remove the daemon handoff here too.
