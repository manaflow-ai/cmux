# nightly.yml wake-nightly-next-tick: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `wake-nightly-next-tick:`:

    # nightly-next-one's end asks main's tick at once. Why: docs/ci/nightly-workflow-notes.md#note-19

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64`:

    # The one-job JIT VM (published-in's), not the mini or a PR-shared Linux runner: the job holds App keys (below).

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 190 || 70 }}`:

    # Room for gh_budget_wait.sh's wait through a rate limit, and for glaeda's capacity wait on the mini.

Above `- &mint-dispatch-pools`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-wake-nightly-next-tick-1.md

Above `- name: Retry the commit that left the slot unless nightly-next moved`:

    # nightly-next-one left without waiting for the promotion on the signing Mac; the wait is the retry's, off it.
