# nightly.yml attest-nightly-remote-daemon: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `needs: [decide, build-nightly-app, build-nightly-remote-daemon, nightly-next-one]`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-attest-nightly-remote-daemon-2.md

Above `if: "!cancelled() && needs.decide.result == 'success' && (needs.build-nightly-app.result == 'success`:

    # A timed-out pick-nightly-build-runner must not skip this job (see build-nightly-app's `if`).

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-attest-nightly-remote-daemon-1.md

Above `- name: Put the pinned Node on PATH`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-attest-nightly-remote-daemon-put-the-pinned-node-on-path.md
