# build-nightly-app: mirror_tool="${GLAEDA_GIT_MIRROR_TOOL:-$HOME/.local/bin/glaeda-git-mirror}"

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `mirror_tool="${GLAEDA_GIT_MIRROR_TOOL:-$HOME/.local/bin/glaeda-git-mirror}"`.

The mirror is fetched from GitHub every minute by the host's one fetcher (glaeda-git-mirror's
LaunchAgent, under a flock). A commit pushed seconds ago may not be in it yet: ask that fetcher for
a pass now and wait for it, instead of fetching from GitHub here.
