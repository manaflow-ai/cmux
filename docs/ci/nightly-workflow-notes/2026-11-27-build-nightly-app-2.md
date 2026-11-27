# 2026-11-27-build-nightly-app-2

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_MINI_BUILDER || github.ref == 'refs/heads/nightly-next' && (needs.pick-nightly-build-runner.outputs.attempt == github.run_attempt && (needs.pick-nightly-build-runner.outputs.trusted && fromJSON(needs.pick-nightly-build-runner.outputs.trusted) || needs.pick-nightly-build-runner.outputs.owned)) || github.repository == 'manaflow-ai/cmux' && github.run_attempt == 1 && needs.decide.outputs.fast_build != 'true' && (github.event_name == 'push' || github.event_name == 'schedule') && github.ref == 'refs/heads/main' && vars.CI_PR_POOL_OWNED == '1' && vars.CI_SEED_TRUSTED_POOL || vars.CI_NIGHTLY_ONLY_RUNNER || 'glaeda-nightly-only-m4pro' }}` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

nightly-next: pick-nightly-build-runner's dedicated builder, else an idle owned
label, else the moving Blacksmith label; never one label with no fallback. Main's
ci-cache-writer environment never follows NEXT onto that worker.
