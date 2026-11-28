# nightly.yml prepare-nightly-variant-primary: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `needs: [decide, build-nightly-ghostty-cli-helper, build-nightly-app, build-nightly-remote-daemon, re`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-primary-1.md

Above `if: "!cancelled() && needs.decide.result == 'success' && needs.build-nightly-ghostty-cli-helper.resu`:

    # A timed-out pick-nightly-build-runner must not skip this job (see build-nightly-app's `if`).

Above `permissions:`:

    # actions:read lets the parallel artifact download resolve the blob URL.

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.run_attempt == 1 &`:

    # Only moves and reads files; Mach-O checks run in verify-signed-nightly. It uses about one core.

Above `submodules: false`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-primary-reuse-a-successful-primary-p-3.md

Above `- &older-tree-step-scripts`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-primary-reuse-a-successful-primary-p-5.md

Above `- &download-nightly-ghostty-license-trees`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-primary-reuse-a-successful-primary-p-4.md

Above `- &prove-the-browser-data-import`:

    # Why: docs/ci/nightly-workflow-notes.md#note-40

Above `if: ${{ (env.PREPARE_FALLBACK != 'true' || steps.reuse.outputs.exists != 'true') && (matrix.variant `:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-primary-2.md

Above `- &upload-prepared-app-for-signin`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-prepare-nightly-variant-primary-3.md
