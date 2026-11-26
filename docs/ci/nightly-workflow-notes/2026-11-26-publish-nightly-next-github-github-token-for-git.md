# publish-nightly-next-github: *github-token-for-git

Where: the `publish-nightly-next-github` job in `.github/workflows/nightly.yml`, above `- *github-token-for-git`.

Only the source archive reads the build's tree; every other step runs .publish-tooling. The full
checkout took 2 min of the whole Mac on run 42018687632, whose archive step was off.
