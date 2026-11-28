# nightly.yml build-nightly-deltas: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `build-nightly-deltas:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-sentry-dsyms-nightly-1.md

Above `NIGHTLY_DELTAS_NEAREST_SHIPPED: ${{ needs.published-build.outputs.track == 'nightly-next' && 'true' `:

    # nightly-next shipped its 3 nearest deltas with the build (hq#13299): only the ~1 and ~3 day bases here.

Above `SPARKLE_DELTA_JOBS: 2`:

    # BinaryDelta peaks near 6 GB a delta; two at a time leave the mini's light work its memory.

Above `- *github-token-for-git`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-27-build-nightly-deltas-1.md

Above `- *wait-through-github-api-rate-l-2`:

    # 2026-11-28 06:30Z (Finish run 46116773791): "Download published variant" died on the installation's spent
    # hour, in the parallel downloader (no spare pool) and then in the action (no wait): the same pair
    # publish-nightly already has.

Above `- name: Select Xcode`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-deltas-select-xcode.md

Above `- name: Download published variant (parallel)`:

    # Why: docs/ci/nightly-workflow-notes.md#note-8

Above `GH_TOKEN_SPARES: ${{ secrets.CI_POOL_TOKEN_1 }} ${{ secrets.CI_POOL_TOKEN_2 }}`:

    # Spent hour: download-run-artifact.py moves to a CI pool's token at once (run 45823496118).

Above `path: ${{ runner.temp }}/nightly-delta/input`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-deltas-download-published-variant.md

Above `- name: Yield the signer Mac to the nightly-next build loop`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-deltas-yield-the-signer-mac-to-the-nightly-nex.md
