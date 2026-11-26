# nightly.yml `close-nightly-failure-issue`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `close-nightly-failure-issue:`

The nightly-next feed alarm (one `nightly-next-feed-stale` issue past
NIGHTLY_NEXT_MAX_FEED_LAG_HOURS) runs from main every 30 minutes, so it also
sees promotion stalls: nightly-next-feed-watch.yml (cx-npz7g).

## 2

Above: `if: always() && needs.published-build.result == 'success' && needs.published-build.outputs.run_tail == 'true' && needs.p`

always(): a skipped notes job must not skip this job silently; the
conditions below decide. nightly-next closes only with its notes published,
unless it published a recovered build, which has none (cx-urd.69). A
recovered build can follow this run's own failed build, which reports.
It closes in the run that ran the notes and deltas (run_tail): on nightly-next, the dispatched one. There
it cannot see the run that published, so push_clean says none of that run's jobs failed.

## 3

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY`

The declared nightly-only mini is enabled after live admission is verified.
Keep the existing fallback; never reuse the stale builder-only placement.
