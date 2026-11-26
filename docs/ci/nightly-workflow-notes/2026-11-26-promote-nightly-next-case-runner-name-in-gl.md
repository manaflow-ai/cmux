# promote-nightly-next: case "${RUNNER_NAME:-}" in *-glaeda|*-glaeda-*) ;; *) [ -d /Users/Shared/cmux-bu

Where: the `promote-nightly-next` job in `.github/workflows/nightly.yml`, above `case "${RUNNER_NAME:-}" in *-glaeda|*-glaeda-*) ;; *) [ -d /Users/Shared/cmux-build-fleet ] || exit …`.

Last, whatever failed: the next job on this mini finds none of this job's tokens or files. Tokens
live in env and in the runner temp dir (gh_app_token.sh's wrapper state); files in the workspace.
