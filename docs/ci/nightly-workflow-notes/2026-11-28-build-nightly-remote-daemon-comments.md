# nightly.yml build-nightly-remote-daemon: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `needs: [decide, resolve-nightly-cmux-tui-client, pick-nightly-build-runner]`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-remote-daemon-1.md

Above `if: "!cancelled() && needs.decide.result == 'success' && needs.resolve-nightly-cmux-tui-client.resul`:

    # A timed-out pick-nightly-build-runner must not skip this job (see build-nightly-app's `if`).

Above `go-version-file: daemon/remote/go.mod`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-remote-daemon-checkout-build-ref.md

Above `overwrite: true`:

    # A picker re-run (owned-pool rescue) re-runs this job after it succeeded beside a stuck app build.
