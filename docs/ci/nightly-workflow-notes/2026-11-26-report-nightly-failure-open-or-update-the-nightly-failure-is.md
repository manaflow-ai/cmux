# nightly.yml: job `report-nightly-failure`, step "Open or update the nightly failure issue"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The nightly-next feed alarm (one `nightly-next-feed-stale` issue past
NIGHTLY_NEXT_MAX_FEED_LAG_HOURS) runs from main every 30 minutes, so it also
sees promotion stalls: nightly-next-feed-watch.yml (cx-npz7g).
