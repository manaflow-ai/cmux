# nightly.yml: job `report-nightly-failure`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A cancelled job (a timeout reports as cancelled) counts as a failure. On
nightly-next the signed release notes are part of the publication: a
published build whose notes jobs did not both succeed is reported too
(run 37526646874 published with its notes job cancelled and no alarm).
