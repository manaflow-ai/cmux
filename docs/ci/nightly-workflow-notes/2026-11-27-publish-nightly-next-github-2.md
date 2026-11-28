# 2026-11-27-publish-nightly-next-github-2

Above `- *github-token-for-git` (job `publish-nightly-next-github`) in `.github/workflows/nightly.yml`.

Only the source archive reads the build's tree; every other step runs .publish-tooling. The full
checkout took 2 min of the whole Mac on run 42018687632, whose archive step was off.
