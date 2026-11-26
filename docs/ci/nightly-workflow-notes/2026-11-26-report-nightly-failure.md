# nightly.yml `report-nightly-failure`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `report-nightly-failure:`

A cancelled job (a timeout reports as cancelled) counts as a failure. On
nightly-next the signed release notes are part of the publication: a
published build whose notes jobs did not both succeed is reported too
(run 37526646874 published with its notes job cancelled and no alarm).

## 2

Above: `if: always() && (needs.decide.outputs.should_publish == 'true' || needs.published-build.outputs.cross_run == 'true' || i`

Twice on nightly-next: the loop run reports its build, feed and dispatch, the dispatched run (cross_run) the
rest. A dispatched run whose published-build fails has no record, so it reports under nightly-next's names.

## 3

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY`

The declared nightly-only mini is enabled after live admission is verified.
Keep the existing fallback; never reuse the stale builder-only placement.
