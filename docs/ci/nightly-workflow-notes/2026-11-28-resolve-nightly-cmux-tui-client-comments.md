# `resolve-nightly-cmux-tui-client`: the comments that were inline

Moved out of `.github/workflows/nightly.yml` on 2026-11-28 to keep the file under the size guard
(tests/test_ci_workflow_file_size.py). Each note names the line it sat above.

- Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.run_attempt == 1 && (github.event_name`: retry-nightly-next dispatches a new run at attempt 1. Use the rerun pool for those dispatches too.
- Above `tree_fallback: ${{ steps.pending.outputs.fallback }}`: "<commit> <key>" of the newest published tree, bundled when the tip's is still unpublished (RFD 0021).
- Above `tree_from: ${{ steps.resolve.outputs.tree_from }}`: "<commit> <commits> <hours>": the older commit whose tree the tip's app bundles (older-tree-for-tip.sh).
- Above `daemon_build: ${{ steps.daemon-build.outputs.build }}`: The build number (<run id><attempt>) for both side-by-side jobs, the app and the daemon.
- Above `fetch-depth: 64`: The resolver searches the last CMUX_TUI_TREE_SEARCH_COMMITS commits.
- Above `- name: Record pending tree dependency`: The selected build source can differ from this workflow's control SHA.
