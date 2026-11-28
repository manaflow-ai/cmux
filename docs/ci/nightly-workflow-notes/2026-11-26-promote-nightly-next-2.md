# 2026-11-26-promote-nightly-next-2

Above `await-release-surface-ack:` (job `promote-nightly-next`) in `.github/workflows/nightly.yml`.

Legacy approval waiter retained for contract compatibility; validated moves now happen in
promote-nightly-next without an environment approval. It reads no secret and writes nothing,
so cancelling it never leaves nightly-next half-moved; the newest request wins its group.

## nightly.yml: job `promote-nightly-next`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Ends on the nightly slot's label as a literal, never vars.CI_NIGHTLY_NEXT_BUILD_RUNNER: main's
repository-variable check (scripts/ci/signing_runner_variables.py) holds a variable a signing job
reads to blacksmith-*/ubuntu-*, and that variable names an owned Mac (#26450).
