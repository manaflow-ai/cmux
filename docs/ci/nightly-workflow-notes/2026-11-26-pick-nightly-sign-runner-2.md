# nightly.yml: job `pick-nightly-sign-runner`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Room for every step budget in turn (the read token mint 1, the owned pick's token mints 1 + 1, the verify picker 2,
the signing picker 2 and the overtaken check 1) plus checkout, so the job is never cut off before its outputs.
