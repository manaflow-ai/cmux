# 2026-11-27-generate-nightly-deltas-2

Above `- *github-token-for-git` (job `generate-nightly-deltas`) in `.github/workflows/nightly.yml`.

Only scripts/ (and, by cone mode, the root .xcode-version) is read from it, so it is sparse: a full
clone took 96 s of the whole-Mac hold (run 42033609306, 14:11:49-14:13:25Z).
