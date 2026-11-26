# attest-nightly-remote-daemon: runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.

Where: the `attest-nightly-remote-daemon` job in `.github/workflows/nightly.yml`, above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '…`.

The owned nightly-only Mac pool first (the all-nightly reservation, as route-visual-gate-nightly),
then the nightly-only pool variable or label, never Blacksmith (nightlies never use Blacksmith). Its OIDC token only
writes provenance for these assets; the pool already builds the nightly app those assets ship in.
