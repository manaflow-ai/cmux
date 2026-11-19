#!/usr/bin/env bash
# The cmux automation `models-scout` runs this (every 6 h, this Mac's runner):
#   cmux automation create models-scout --command 'bash ~/cmux-worktrees/models-scout/scripts/models/run-scout.sh' \
#     --every 6h --timeout 20m --catch-up latest
# It runs scripts/models/scout.ts from the newest feat-cmux-next in its own worktree (never a shared
# checkout), so a fix to the scout or the overrides lands and the next run uses it. Exit codes are the
# scout's: 0 ok, 3 a failed check (the runner shows and notifies it), 1 a crash.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
# Only this worktree (made for the scout) is moved; a checkout someone works in is left alone.
if [ "$(basename "$here")" = models-scout ] && [ -z "$(git -C "$here" status --porcelain)" ]; then
  if git -C "$here" fetch -q origin feat-cmux-next; then
    git -C "$here" checkout -q --detach FETCH_HEAD
  else
    echo "fetch failed; running the scout this worktree has" >&2
  fi
fi
exec bun "$here/scripts/models/scout.ts" "$@"
