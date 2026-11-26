# build-nightly-deltas: Select Xcode

Where: the `build-nightly-deltas` job in `.github/workflows/nightly.yml`, above `- name: Select Xcode`.

BinaryDelta runs with the Xcode the keyed job selects; the script reads .xcode-version and the pins from
its own checkout (cone mode keeps the root files).
