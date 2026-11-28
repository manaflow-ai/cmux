# nightly.yml: job `find-nightly-next-recovery`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A drained owned Mac for recover-nightly-next-notarization (glaeda's exclusive class) and
verify-recovered-nightly-next, as the JSON runs-on array scripts/ci/signing_runner.py prints, or
empty. They read it only while `attempt` is the run's own attempt.
