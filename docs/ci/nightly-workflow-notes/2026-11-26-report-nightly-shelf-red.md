# nightly.yml `report-nightly-shelf-red`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `report-nightly-shelf-red:`

The App Store shelf is advisory: a red opens or updates an issue and never holds the publish (Leo, 2026-11-25:
"some of these checks are they too frivolous to block nightly on? we need to make sure we can just have stuff be ok").
