# nightly.yml resolve-nightly-cmux-tui-client: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.run_attempt == 1 &`:

    # retry-nightly-next dispatches a new run at attempt 1. Use the rerun pool for those dispatches too.

Above `tree_fallback: ${{ steps.pending.outputs.fallback }}`:

    # "<commit> <key>" of the newest published tree, bundled when the tip's is still unpublished (RFD 0021).

Above `tree_from: ${{ steps.resolve.outputs.tree_from }}`:

    # "<commit> <commits> <hours>": the older commit whose tree the tip's app bundles (older-tree-for-tip.sh).

Above `daemon_build: ${{ steps.daemon-build.outputs.build }}`:

    # The build number (<run id><attempt>) for both side-by-side jobs, the app and the daemon.

Above `GH_TOKEN_SPARES: ${{ secrets.CI_POOL_TOKEN_1 }} ${{ secrets.CI_POOL_TOKEN_2 }}`:

    # A second path for every gh call (c-bedbdb1917): a refused github.token hour moves to a CI pool's own
    # hour at once (gh_budget_wait.sh); a write the read-only pool cannot do goes back and waits as before.

Above `fetch-depth: 64`:

    # The resolver searches the last CMUX_TUI_TREE_SEARCH_COMMITS commits.

Above `- name: Pack the build source for later jobs`:

    # The build commit's source once per run, from this mirror-served checkout: later jobs unpack it
    # instead of fetching from github.com (scripts/ci/nightly-source.sh).

Above `- name: Pack this workflow commit's scripts`:

    # This workflow commit's scripts/ci, for retry-nightly-next and report-nightly-failure: 0 github.com fetches.

Above `- name: Record pending tree dependency`:

    # The selected build source can differ from this workflow's control SHA.
