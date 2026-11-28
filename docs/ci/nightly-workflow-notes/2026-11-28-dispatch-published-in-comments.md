# nightly.yml dispatch-published-in: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `dispatch-published-in:`:

    # Why: docs/ci/nightly-workflow-notes.md#note-49

Above `needs: [decide, build-nightly-ghostty-cli-helper, build-nightly-app, build-sign-notarize-nightly, re`:

    # The build jobs too: the record says whether any of them failed (push_clean).

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64`:

    # The one-job JIT VM (published-in's), not the mini or a PR-shared Linux runner: the job holds App keys (wake-nightly-next-tick's).

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 190 || 70 }}`:

    # Room for gh_budget_wait.sh's wait through a rate limit, and for glaeda's capacity wait on the mini.

Above `- name: Read the feed back before saying published`:

    # A run that says published reads the live feeds first: an unmoved feed fails here, red, and a refused build
    # (nightly-next-one reds a real refusal) asks for no post-publication run (2026-11-25, run 45607031207).

Above `- name: Upload the record`:

    # The tail run reads the record only from here (published-build), never from its input.

Above `env: *dispatch-pools`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-dispatch-published-in-1.md
    # A 422 "twirp error resource_exhausted" is GitHub failing to read the workflow file (45798252585): tried again like a 5xx.
