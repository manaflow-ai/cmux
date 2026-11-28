# nightly.yml prepare-nightly-variant-primary: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `if: "!cancelled() && needs.decide.result == 'success' && needs.build-nightly-ghostty-cli-helper.resu`:

    # A timed-out pick-nightly-build-runner must not skip this job (see build-nightly-app's `if`).

Above `permissions:`:

    # actions:read lets the parallel artifact download resolve the blob URL.

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.run_attempt == 1 &`:

    # Only moves and reads files; Mach-O checks run in verify-signed-nightly. It uses about one core.
