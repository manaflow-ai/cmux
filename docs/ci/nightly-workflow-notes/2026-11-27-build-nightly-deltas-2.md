# 2026-11-27-build-nightly-deltas-2

Above `- name: Select Xcode` (job `build-nightly-deltas`) in `.github/workflows/nightly.yml`.

BinaryDelta runs with the Xcode the keyed job selects; the script reads .xcode-version and the pins from
its own checkout (cone mode keeps the root files).
