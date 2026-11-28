# nightly.yml generate-nightly-deltas: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `- *claim-publication-mac`:

    # The build ref may predate the hook list.

Above `GH_TOKEN_SPARES: ${{ secrets.CI_POOL_TOKEN_1 }} ${{ secrets.CI_POOL_TOKEN_2 }}`:

    # Spent hour: download-run-artifact.py moves to a CI pool's token at once (run 45823496118).

Above `run-id: ${{ needs.published-build.outputs.source_run || github.run_id }}`:

    # From the run that published (the dispatched run's published-build names it).

Above `- name: Download the prebuilt deltas`:

    # build-nightly-deltas' files; a missing one is built below, as before.

Above `SHARED_SPARKLE_PRIVATE_KEY: ${{ needs.published-build.outputs.track != 'nightly-next' && secrets.SPA`:

    # The nightly-next track gets only its own key; the others never see it.
