# nightly.yml: job `pick-nightly-sign-runner`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A drained (or draining) owned Mac for the release signing jobs, as the JSON runs-on
array scripts/ci/signing_runner.py prints, or empty, under the same marker and `attempt` rules as `owned`.
