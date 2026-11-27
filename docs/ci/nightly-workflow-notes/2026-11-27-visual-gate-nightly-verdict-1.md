# 2026-11-27-visual-gate-nightly-verdict-1

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_MINI || github.repository == 'manaflow-ai/cmux' && needs.decide.outputs.track == 'nightly-next' && github.run_attempt == 1 && vars.CI_NIGHTLY_ONLY_RUNNER == 'glaeda-nightly-only-m4pro' && vars.CI_NIGHTLY_ONLY_RUNNER || vars.CI_NIGHTLY_ONLY_RUNNER || 'glaeda-nightly-only-m4pro' }}` (job `visual-gate-nightly-verdict`) in `.github/workflows/nightly.yml`.

The declared nightly-only mini is enabled after live admission is verified.
Keep the existing fallback; never reuse the stale builder-only placement.
