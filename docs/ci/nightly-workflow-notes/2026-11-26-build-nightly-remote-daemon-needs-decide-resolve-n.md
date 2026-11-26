# build-nightly-remote-daemon: needs: [decide, resolve-nightly-cmux-tui-client, pick-nightly-build-runner]

Where: the `build-nightly-remote-daemon` job in `.github/workflows/nightly.yml`, above `needs: [decide, resolve-nightly-cmux-tui-client, pick-nightly-build-runner]`.

Pure Go (CGO_ENABLED=0), manifests and uploads do not need the app builder, so it
builds beside build-nightly-app (its `if`), on the Ghostty helper's owned Mac pick,
else the owned nightly-only Mac pool (the all-nightly reservation on NEXT's first attempt; run
41683652930 took blacksmith-32vcpu-ubuntu-2404), else the nightly-only pool: never Blacksmith. Resume already retained these exact assets in build-nightly-app.
