# build-nightly-app: runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_N

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_NIGHTLY_MINI != '' &&…`.

nightly-next: pick-nightly-build-runner's dedicated builder, else an idle owned
label, else the moving Blacksmith label; never one label with no fallback. Main's
ci-cache-writer environment never follows NEXT onto that worker.
