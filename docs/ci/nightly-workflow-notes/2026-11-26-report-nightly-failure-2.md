# nightly.yml: job `report-nightly-failure`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Twice on nightly-next: the loop run reports its build, feed and dispatch, the dispatched run (cross_run) the
rest. A dispatched run whose published-build fails has no record, so it reports under nightly-next's names.
