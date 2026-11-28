#!/usr/bin/env bash
# One-off A/B for goal infinite-items-flat: the board's own infinite-items pass at n=1000 (pages=0 days=1 --window=5,
# as perf-cron.py runs it), then the same build with the daemon's freeing timer shortened to 30 s
# (--free-idle-seconds=30, #46795's workspaces.freeing timer). Prints the INFINITE-DAY lines with each role's
# thread wakeups (woke=...), so the idle wakeups have an owner.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
echo "IIF-ARM default"
bash "$here/infinite-items-linux.sh" counts=1000 pages=0 days=1 --window=5 2>&1 | sed -u 's/^/DEFAULT /'
echo "IIF-ARM freed30"
bash "$here/infinite-items-linux.sh" counts=1000 pages=0 days=1 --window=5 --free-idle-seconds=30 2>&1 | sed -u 's/^/FREED30 /'
