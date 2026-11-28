# nightly.yml build-nightly-ghostty-cli-helper: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `if: "!cancelled() && needs.decide.result == 'success' && needs.resolve-nightly-cmux-tui-client.resul`:

    # A timed-out pick-nightly-build-runner must not skip this job (see build-nightly-app's `if`).

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_NIGHTLY_MINI != '' &&`:

    # Why: docs/ci/nightly-workflow-notes.md#note-23

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 150 || 30 }}`:

    # zig-fetch-all.sh may retry each source-archive fetch (about 8.5 min at most per tree).

Above `- &select-xcode-sdk-unless-resumed`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-ghostty-cli-helper-checkout-helper-ref-2.md

Above `- &x2`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-ghostty-cli-helper-checkout-helper-ref.md

Above `GH_DOWNLOAD_TOKEN: ${{ github.token }}`:

    # The Zig package mirror is a github.com release; the Macs get 403 on anonymous downloads.

Above `- name: Strip the Ghostty CLI helper`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-ghostty-cli-helper-1.md

Above `overwrite: true`:

    # A reuse upload that failed part-way may have left the name taken.

Above `GH_DOWNLOAD_TOKEN: ${{ github.token }}`:

    # The Zig package mirror is a github.com release; the Macs get 403 on anonymous downloads.

Above `overwrite: true`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-ghostty-cli-helper-upload-ghostty-cli-helper-r.md

Above `- name: Upload cmux-next license trees`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-ghostty-cli-helper-upload-cmux-next-license-tr.md

Above `overwrite: true`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-ghostty-cli-helper-upload-cmux-next-license-tr-2.md
