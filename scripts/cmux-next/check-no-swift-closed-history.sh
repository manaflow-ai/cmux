#!/usr/bin/env bash
# Fails when a Swift closed history comes back. The daemon owns the closed
# log (closed-history-v2, plans/cmux-next/reopen-closed.md 1 and 9): the app
# reads `closed.list` through `DaemonClosedHistory` and reopens with
# `closed.reopen`; it keeps no closed tabs, screens or workspaces of its own.
# A merge from main or an old branch can bring a tracker back.
#
# Checks tracked Swift files only, so a stray local build directory is ignored.
# Usage: scripts/cmux-next/check-no-swift-closed-history.sh [repo-root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)}"
# POSIX ERE (git grep -E has no \b): a name ends at a non-letter or the line end.
pattern='(ClosedTabTracker|ClosedTabHistory|ClosedScreenHistory|ClosedWorkspaceTracker|ClosedWorkspaceLog|ClosedTerminalRestorer)([^A-Za-z]|$)|(class|struct|actor|enum) Closed[A-Za-z]*(Tracker|History|Log)([^A-Za-z]|$)'
hits=$(git -C "$root" grep -nE "$pattern" -- 'Packages/macOS/CmuxNext/*.swift' || true)
if [[ -n "$hits" ]]; then
  echo "check-no-swift-closed-history: a Swift closed history is back. The daemon owns the closed log (plans/cmux-next/reopen-closed.md 9); read it through DaemonClosedHistory:" >&2
  echo "$hits" >&2
  exit 1
fi
echo "check-no-swift-closed-history: ok"
