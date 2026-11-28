# `publish-nightly-next-github`: the comments that were inline

Moved out of `.github/workflows/nightly.yml` on 2026-11-28 to keep the file under the size guard
(tests/test_ci_workflow_file_size.py). Each note names the line it sat above.

- Above `environment: ${{ github.ref == 'refs/heads/nightly-next' && 'release-next' || 'release' }}`: Nothing on the feed's path needs this job, so a failure shows red and holds nothing.
- Above `timeout-minutes: 240`: The two former jobs' limits added up: the uploads and the names each may wait out an hour of rate limits.
- Above `run-id: ${{ needs.published-build.outputs.source_run || github.run_id }}`: From the run that published (the dispatched run's published-build names it).
- Above `run-id: ${{ needs.published-build.outputs.source_run || github.run_id }}`: From the run that published (the dispatched run's published-build names it).
- Above `run-id: ${{ needs.published-build.outputs.source_run || github.run_id }}`: From the run that published (the dispatched run's published-build names it).
- Above `run-id: ${{ needs.published-build.outputs.source_run || github.run_id }}`: From the run that published (the dispatched run's published-build names it).
- Above `run-id: ${{ needs.published-build.outputs.source_run || github.run_id }}`: From the run that published (the dispatched run's published-build names it).
- Above `LEASE_MAX_HOLD: 10800`: The names writes may wait out an hour of rate limits, as the job's timeout allows.
