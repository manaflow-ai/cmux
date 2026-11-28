# nightly.yml report-nightly-shelf-red: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `if: "!cancelled() && (needs.check-nightly-app-store-shelf.result == 'failure' || needs.check-nightly`:

    # A cancelled (timed-out) shelf check is a red too: report it.

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '`:

    # issues: write, so the nightly-only route every nightly report job takes, never the PR-shared cmux-linux pool.
