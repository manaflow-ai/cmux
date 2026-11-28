# `publish-nightly`: the comments that were inline

Moved out of `.github/workflows/nightly.yml` on 2026-11-28 to keep the file under the size guard
(tests/test_ci_workflow_file_size.py). Each note names the line it sat above.

- Above `build: ${{ steps.source.outputs.build }}`: The published build.
- Above `build_sha: ${{ steps.source.outputs.build_sha }}`: Its commit, for keep-published-dsyms.
- Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 300 || 180 }}`: 120 for the work (an hour of it for API rate-limit waits) plus the lease's 60-minute wait.
- Above `NIGHTLY_FEEDS: ${{ needs.decide.outputs.feeds }}`: The appcasts this track publishes (decide): one on nightly-next, four on main.
- Above `PUBLISH_TOOLING: &pub-tooling ${{ github.workspace }}/.publish-tooling/scripts`: Publication tooling from this workflow's own commit (see the step below).
- Above `- *hold-the-whole-mac`: First, before any checkout or secret: the whole mini (glaeda's exclusive class), as the signing jobs.
- Above `OWN_TREE: ${{ (needs.resolve-nightly-cmux-tui-client.outputs.tree_pending != 'true' && inputs.nightly_next_unsigned_run `: NIGHTLY_NEXT_TREE_AT_INSTALL: a build made before its tree published, or resumed, needs await-nightly-tree-marker.
- Above `- &claim-publication-mac`: Before any release App secret: the claim again, and a keychain a killed job left is removed.
- Above `GH_TOKEN_SPARES: ${{ secrets.CI_POOL_TOKEN_1 }} ${{ secrets.CI_POOL_TOKEN_2 }}`: Spent hour: download-run-artifact.py moves to a CI pool's token at once (run 45823496118).
- Above `LEASE_KEY: nightly-next/locks/publish-nightly-next.json`: Shared with publish-release-notes: notes ordering relies on the same lock.
- Above `NOTES_APP_NAME: ${{ needs.decide.outputs.track == 'nightly-next' && 'cmux NIGHTLY' || needs.decide.outputs.app_name }}`: nightly-next ships as cmux NIGHTLY (hq#7156).
- Above `github-token: ${{ steps.source.outputs.language_packs_run != '' && github.token || '' }}`: Only another run's packs need the REST API (and its installation rate limit).
