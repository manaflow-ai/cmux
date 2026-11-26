# report-nightly-failure: runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.

Where: the `report-nightly-failure` job in `.github/workflows/nightly.yml`, above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '…`.

The declared nightly-only mini is enabled after live admission is verified.
Keep the existing fallback; never reuse the stale builder-only placement.
