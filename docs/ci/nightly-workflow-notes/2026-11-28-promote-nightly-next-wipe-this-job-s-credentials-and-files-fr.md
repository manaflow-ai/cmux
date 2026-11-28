# 2026-11-28-promote-nightly-next-wipe-this-job-s-credentials-and-files-fr

Where: `.github/workflows/nightly.yml`, job `promote-nightly-next`, step "Wipe this job's credentials and files from the owned Mac": above `case "${RUNNER_NAME:-}" in *-glaeda|*-glaeda-*) ;; *) [ -d /Users/Shared/cmux-build-fleet ] || exit `.

Last, whatever failed: the next job on this mini finds none of this job's tokens or files. Tokens live in env and in the runner temp dir (gh_app_token.sh's wrapper state); files in the workspace.
