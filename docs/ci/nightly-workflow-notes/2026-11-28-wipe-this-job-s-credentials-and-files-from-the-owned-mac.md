# 2026-11-28-wipe-this-job-s-credentials-and-files-from-the-owned-mac

Where: `.github/workflows/nightly.yml`, Wipe this job's credentials and files from the owned Mac.

Last, whatever failed: the next job on this mini finds none of this job's tokens or files. Tokens live in env and in the runner temp dir (gh_app_token.sh's wrapper state); files in the workspace.
