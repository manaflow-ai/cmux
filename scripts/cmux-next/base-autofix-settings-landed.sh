#!/usr/bin/env bash
# After base autofix lands (cmux-next-base-autofix.yml, a run with the settings area on): fails when the
# settings exports at the newest BRANCH tip are still stale (defaults_guard.py check-stamp) for the same
# settings sources RUN_SHA had. A green run moves the next run's "since" (base-autofix-since.sh) past its
# changes, so a run that left those exports stale would hand them to no run (#22740's export, 2026-10-21).
# When a newer commit changed the sources, the exports are the next run's work: a warning only.
#
# Usage: scripts/cmux-next/base-autofix-settings-landed.sh REMOTE BRANCH RUN_SHA   (run in the checkout)
set -euo pipefail
remote="${1:?usage: $0 REMOTE BRANCH RUN_SHA}"
branch="${2:?usage: $0 REMOTE BRANCH RUN_SHA}"
run="${3:?usage: $0 REMOTE BRANCH RUN_SHA}"
guard="$(git rev-parse --show-toplevel)/scripts/ci/defaults_guard.py"
git fetch --quiet --no-tags "$remote" "refs/heads/$branch"
tip="$(git rev-parse FETCH_HEAD)"
if python3 "$guard" check-stamp --ref "$tip" >&2; then
  echo "The settings exports at ${tip:0:12} are current."
  exit 0
fi
if ! run_stamp="$(python3 "$guard" source-stamp --ref "$run")" \
  || ! tip_stamp="$(python3 "$guard" source-stamp --ref "$tip")" \
  || [[ "$run_stamp" == "$tip_stamp" ]]; then
  echo "::error::the settings exports at ${tip:0:12} are still stale for the settings sources this run had at ${run:0:12}; the next run makes them again"
  exit 1
fi
echo "::warning::the settings exports at ${tip:0:12} are stale, but a commit after ${run:0:12} changed the settings sources; the next run makes them"
