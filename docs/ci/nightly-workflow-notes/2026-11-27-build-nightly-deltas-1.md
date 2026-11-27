# 2026-11-27-build-nightly-deltas-1

Above `- *github-token-for-git` (job `build-nightly-deltas`) in `.github/workflows/nightly.yml`.

Publication tooling at the workflow commit: it has the keyless mode even when the build commit predates
it, and it ships no source (only scripts/, into .publish-tooling).
