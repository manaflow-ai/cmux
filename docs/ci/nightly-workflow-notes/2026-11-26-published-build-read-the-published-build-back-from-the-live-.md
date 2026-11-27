# nightly.yml: job `published-build`, step "Read the published build back from the live feed"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The job's own claim, read back: the build it says went out is on the live nightly-next feed (Leo's app reads
it), as its newest item or under a newer build that already published. Red here stops the dispatch and the tail.
