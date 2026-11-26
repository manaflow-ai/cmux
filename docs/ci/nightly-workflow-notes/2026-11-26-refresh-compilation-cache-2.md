# 2026-11-26-refresh-compilation-cache-2

Above `- &clear-stale-git-locks-self-hos` (job `refresh-compilation-cache`) in `.github/workflows/nightly.yml`.

Steps repeated byte for byte across jobs are written once (a YAML anchor, `&name`) and
reused (`*name`): GitHub refuses a workflow file over 512,000 bytes before any job starts.
Edit the anchored copy; every alias follows it. tests/test_nightly_workflow_size.py keeps the limit.
