# nightly.yml report-nightly-failure: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `report-nightly-failure:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-fixit-handoff-1.md

Above `if: always() && (needs.decide.outputs.should_publish == 'true' || needs.published-build.outputs.cros`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-report-nightly-failure-2.md

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-report-nightly-failure-3.md

Above `actions: read`:

    # The replaced-build check lists this run's jobs.

Above `HEAD_SHA: ${{ needs.resolve-nightly-cmux-tui-client.outputs.build_sha || needs.published-build.outpu`:

    # In the dispatched run, decide and the build jobs skipped: the record names the build.

Above `TIP_SHA: ${{ needs.decide.outputs.head_sha || needs.published-build.outputs.head_sha }}`:

    # The pushed nightly-next head (HEAD_SHA can be an older resolved build commit).

Above `close-nightly-failure-issue:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-report-nightly-failure-open-or-update-the-nightly-failure-is.md
