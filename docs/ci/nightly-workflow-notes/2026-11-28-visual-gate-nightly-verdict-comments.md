# nightly.yml visual-gate-nightly-verdict: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `visual-gate-nightly-verdict:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-visual-gate-nightly-verdict.md

Above `if: "!cancelled() && needs.verify-final-dmg-nightly.result == 'success' && needs.route-visual-gate-n`:

    # A skipped signing path must not skip this job (implicit success()).

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-visual-gate-nightly-verdict-2.md

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 220 || 100 }}`:

    # A re-run's 15 + 75 min, plus slack; attempt 1 waits at most 10.
