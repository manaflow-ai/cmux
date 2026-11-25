# 2026-11-24-macos-placement-3

Above `[[ "$QUIET_SECONDS" =~ ^[0-9]+$ ]] || QUIET_SECONDS=300` in the step `Wait until the pull request has had no push for the quiet period`'s script (job `macos-placement`) in `.github/workflows/cmux-next.yml`.

At most 10 minutes, whatever the variable says.
