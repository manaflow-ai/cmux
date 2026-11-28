# nightly.yml publish-nightly: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `environment: ${{ needs.decide.outputs.environment }}`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-4.md

Above `concurrency:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-1.md

Above `build: ${{ steps.source.outputs.build }}`:

    # The published build.

Above `build_sha: ${{ steps.source.outputs.build_sha }}`:

    # Its commit, for keep-published-dsyms.

Above `already_published: ${{ steps.recheck.outputs.already_published == 'true' || steps.gate.outputs.refus`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-7.md

Above `refused: ${{ steps.gate.outputs.refused == 'true' || steps.recheck.outputs.superseded == 'true' || s`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-2.md

Above `variant_pattern: ${{ steps.source.outputs.variant_pattern }}`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-6.md

Above `if: "always() && !cancelled() && needs.decide.result == 'success' && needs.decide.outputs.should_bui`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-5.md

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI_PUBL`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-3.md

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 300 || 180 }}`:

    # 120 for the work (an hour of it for API rate-limit waits) plus the lease's 60-minute wait.

Above `NIGHTLY_FEEDS: ${{ needs.decide.outputs.feeds }}`:

    # The appcasts this track publishes (decide): one on nightly-next, four on main.

Above `PUBLISH_TOOLING: &pub-tooling ${{ github.workspace }}/.publish-tooling/scripts`:

    # Publication tooling from this workflow's own commit (see the step below).

Above `- *hold-the-whole-mac`:

    # First, before any checkout or secret: the whole mini (glaeda's exclusive class), as the signing jobs.

Above `OWN_VERIFIED: ${{ needs.verify-signed-nightly.result }}`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-select-the-build-to-publish-2.md

Above `OWN_TREE: ${{ (needs.resolve-nightly-cmux-tui-client.outputs.tree_pending != 'true' && inputs.nightl`:

    # NIGHTLY_NEXT_TREE_AT_INSTALL: a build made before its tree published, or resumed, needs await-nightly-tree-marker.

Above `CEF_ON_DEMAND: ${{ vars.CMUX_NEXT_CEF_ON_DEMAND }}`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-select-the-build-to-publish.md

Above `- *checkout-publication-tooling-a`:

    # Why: docs/ci/nightly-workflow-notes.md#note-45

Above `- &claim-publication-mac`:

    # Before any release App secret: the claim again, and a keychain a killed job left is removed.

Above `- &gh-app-token-write`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-checkout-publish-ref-2.md

Above `run: if [ -f .publish-tooling/scripts/ci/gh_budget_wait.sh ]; then bash .publish-tooling/scripts/ci/`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-4.md

Above `- name: Download nightly variant artifacts (parallel)`:

    # Why: docs/ci/nightly-workflow-notes.md#note-8

Above `GH_TOKEN_SPARES: ${{ secrets.CI_POOL_TOKEN_1 }} ${{ secrets.CI_POOL_TOKEN_2 }}`:

    # Spent hour: download-run-artifact.py moves to a CI pool's token at once (run 45823496118).

Above `- name: Download verified DMG digests`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-download-verified-dmg-digests.md

Above `- &x81`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-25-nightly-next-feed-lease.md

Above `LEASE_KEY: nightly-next/locks/publish-nightly-next.json`:

    # Shared with publish-release-notes: notes ordering relies on the same lock.

Above `NOTES_APP_NAME: ${{ needs.decide.outputs.track == 'nightly-next' && 'cmux NIGHTLY' || needs.decide.o`:

    # nightly-next ships as cmux NIGHTLY (hq#7156).

Above `- &x87`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-6.md

Above `- &x88`:

    # Why: docs/ci/nightly-workflow-notes.md#note-14

Above `NIGHTLY_COMPONENT_GATES: ${{ vars.NIGHTLY_COMPONENT_GATES }}`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-27-publish-nightly-8.md

Above `app-id: ${{ secrets.CMUX_RELEASE_APP_ID }}`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-mint-release-tag-app-token.md

Above `- &x91m`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-write-the-build-manifest-for-this-app-input-.md

Above `- name: Download the Chromium runtime pack`:

    # Why: docs/ci/nightly-workflow-notes.md#note-3

Above `- name: Download the language packs`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-download-the-language-packs.md

Above `github-token: ${{ steps.source.outputs.language_packs_run != '' && github.token || '' }}`:

    # Only another run's packs need the REST API (and its installation rate limit).
