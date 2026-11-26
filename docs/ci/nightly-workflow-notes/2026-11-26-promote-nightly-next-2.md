# nightly.yml: job `promote-nightly-next`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Ends on the nightly slot's label as a literal, never vars.CI_NIGHTLY_NEXT_BUILD_RUNNER: main's
repository-variable check (scripts/ci/signing_runner_variables.py) holds a variable a signing job
reads to blacksmith-*/ubuntu-*, and that variable names an owned Mac (#26450).
