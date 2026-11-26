# build-nightly-deltas: *github-token-for-git

Where: the `build-nightly-deltas` job in `.github/workflows/nightly.yml`, above `- *github-token-for-git`.

Publication tooling at the workflow commit: it has the keyless mode even when the build commit predates
it, and it ships no source (only scripts/, into .publish-tooling).
