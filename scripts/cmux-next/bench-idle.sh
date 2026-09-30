#!/usr/bin/env bash
# Idle benchmark (plans/cmux-next/idle-wakeups.md, architecture.md section 5).
#
# Launches the tagged app (clean environment, no activation, last screen,
# scratch config) and measures CPU and wakeups of the app, its cmux-tui
# daemon and terminal hosts, and each Chromium helper while nothing
# changes: terminals only, plus a static Chromium tab, with that tab's
# workspace hidden, and with the window minimized. Pass criteria: app and
# daemon near 0% CPU and near 0 wakeups/s, helpers near 0% for the static
# and hidden page. Dogfood builds report its result.
#
# Usage:
#   scripts/cmux-next/bench-idle.sh <tag> [--app PATH] [--measure 60] [--settle 20]
#       [--scenarios terminals,chromium-static,chromium-hidden,minimized]
#       [--url URL] [--label NAME] [--out DIR] [--no-fail] [--keep-running]
#       [--max-cpu 0.5] [--max-wakeups 5] [--max-host-cpu 0.2]
#       [--max-host-wakeups 2] [--max-helper-cpu 1.0]
#
# Writes artifacts/cmux-next-bench/<sha>-idle-<label>.json; exits 1 when a
# criterion fails (unless --no-fail). The tagged app must not be running.
set -euo pipefail
if [[ $# -lt 1 || "$1" == -* ]]; then
  sed -n '2,22p' "$0"
  exit 2
fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
sha="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
exec python3 "$repo_root/scripts/cmux-next/bench_idle.py" --repo-root "$repo_root" --sha "$sha" --tag "$@"
