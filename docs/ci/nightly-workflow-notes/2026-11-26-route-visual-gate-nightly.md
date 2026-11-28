# nightly.yml: job `route-visual-gate-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The visual gate (docs/ci/nightly-next-visual-gate.md): light and dark stills of a DEV build of
this run's commit on an idle owned Mac, checked beside the signed build. Skipped (`unavailable`)
with no idle runner; only `enforce` with a failing verdict holds this run's build.
