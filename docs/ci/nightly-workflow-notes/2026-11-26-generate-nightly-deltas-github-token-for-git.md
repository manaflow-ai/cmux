# generate-nightly-deltas: *github-token-for-git

Where: the `generate-nightly-deltas` job in `.github/workflows/nightly.yml`, above `- *github-token-for-git`.

Only scripts/ (and, by cone mode, the root .xcode-version) is read from it, so it is sparse: a full
clone took 96 s of the whole-Mac hold (run 42033609306, 14:11:49-14:13:25Z).
