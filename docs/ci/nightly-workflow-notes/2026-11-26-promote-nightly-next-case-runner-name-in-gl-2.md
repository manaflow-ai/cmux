# promote-nightly-next: case "${RUNNER_NAME:-}" in *-glaeda|*-glaeda-*) ;; *) [ -d /Users/Shared/cmux-bu

Where: the `promote-nightly-next` job in `.github/workflows/nightly.yml`, above `case "${RUNNER_NAME:-}" in *-glaeda|*-glaeda-*) ;; *) [ -d /Users/Shared/cmux-build-fleet ] || exit …`.

Before any checkout or secret: an earlier job's files (a DMG, a feed, notes) never reach this one.
The runner empties its temp dir itself; the workspace stays between jobs on an owned Mac.
