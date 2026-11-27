# 2026-11-26-attest-nightly-remote-daemon-1

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_MINI || github.repository == 'manaflow-ai/cmux' && github.ref == 'refs/heads/nightly-next' && github.run_attempt == 1 && vars.CI_NIGHTLY_ONLY_RUNNER == 'glaeda-nightly-only-m4pro' && vars.CI_NIGHTLY_ONLY_RUNNER || vars.CI_NIGHTLY_ONLY_RUNNER || 'glaeda-nightly-only-m4pro' }}` (job `attest-nightly-remote-daemon`) in `.github/workflows/nightly.yml`.

The owned nightly-only Mac pool first (the all-nightly reservation, as route-visual-gate-nightly),
then the nightly-only pool variable or label, never Blacksmith (nightlies never use Blacksmith). Its OIDC token only
writes provenance for these assets; the pool already builds the nightly app those assets ship in.
