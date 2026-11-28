# nightly.yml check-nightly-webviews: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `check-nightly-webviews:`:

    # Why: docs/ci/nightly-workflow-notes.md#note-39

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-linux' }}`:

    # Bun, Node and Python only, no secret: the Linux pool, never a Mac (docs/ci/nightly-workflow-notes.md#note-51).

Above `fixit_nofix: ${{ steps.fixit-nofix.outputs.nofix }}`:

    # fixit-compile found no machine fix for the type check: the fixit-handoff job dispatches its revert.

Above `- name: Webview checks on the build commit`:

    # Lint-class reds report and are fixed forward (Leo 2026-11-20); typecheck blocks.

Above `- name: Hand a type error with no machine fix to fixit-handoff`:

    # A type error fixit-compile could not fix wrote its record (scripts/ci/oops/fixit_handoff.py signal).
