# nightly.yml find-nightly-next-recovery: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '`:

    # It reads the routing App key, so it stays on the nightly-only pool, whose minis run only nightly.yml.

Above `environment:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-find-nightly-next-recovery-2.md

Above `sign_owned: ${{ steps.sign-owned.outputs.owned }}`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-find-nightly-next-recovery-1.md

Above `- name: Pick a drained owned Mac for the recovery jobs`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-find-nightly-next-recovery-pick-a-drained-owned-mac-for-the-.md
