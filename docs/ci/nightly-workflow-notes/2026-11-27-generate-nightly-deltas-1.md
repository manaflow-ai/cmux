# 2026-11-27-generate-nightly-deltas-1

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_NIGHTLY_MINI != '' && 'glaeda-trusted-next-signing' || needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && needs.pick-nightly-sign-runner.outputs.sign_owned && fromJSON(needs.pick-nightly-sign-runner.outputs.sign_owned) || 'glaeda-trusted-next-signing' }}` (job `generate-nightly-deltas`) in `.github/workflows/nightly.yml`.

Never Blacksmith (Lawrence, 2026-10-30). A Sparkle key: placed and held whole as the legacy sign. Optional:
a failed or refused delta never fails the run or holds the feed. NIGHTLY_DELTAS=off skips them.
