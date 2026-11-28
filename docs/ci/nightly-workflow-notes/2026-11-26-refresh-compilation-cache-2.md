# 2026-11-26-refresh-compilation-cache-2

Above `- &clear-stale-git-locks-self-hos` (job `refresh-compilation-cache`) in `.github/workflows/nightly.yml`.

Steps repeated byte for byte across jobs are written once (a YAML anchor, `&name`) and
reused (`*name`): GitHub refuses a workflow file over 512,000 bytes before any job starts.
Edit the anchored copy; every alias follows it. tests/test_nightly_workflow_size.py keeps the limit.

## nightly.yml: job `refresh-compilation-cache`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Steps repeated byte for byte across jobs are written once (a YAML anchor, `&name`) and
reused (`*name`): GitHub refuses a workflow file over 512,000 bytes before any job starts.
Edit the anchored copy; every alias follows it. tests/test_nightly_workflow_size.py keeps the limit.
