# nightly.yml pick-nightly-next-signer: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `continue-on-error: true`:

    # Any failure leaves the outputs empty: nightly-next-one then takes the signer label alone and cmux15's group.

Above `environment:`:

    # The signer picker mints the same read-only routing token as pick-nightly-sign-runner.

Above `host: ${{ steps.pick.outputs.host }}`:

    # cmux15 or ultra1 (nightly-next-one's group, nightly-next-one-push-<host>).

Above `pin: ${{ steps.pick.outputs.pin }}`:

    # The JSON runs-on array; it always starts with the literal glaeda-trusted-next-signing.
