# attest-nightly-remote-daemon: resolve-nightly-cmux-tui-client:

Where: the `attest-nightly-remote-daemon` job in `.github/workflows/nightly.yml`, above `resolve-nightly-cmux-tui-client:`.

Runs beside build-nightly-app. Deepening the shallow clone to find the
newest published cmux-tui commit took 1.5 to 11 minutes after the Xcode
compile (runs 36044415287, 36051668491); here it overlaps the compile.
