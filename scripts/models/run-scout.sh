#!/usr/bin/env bash
# The cmux automation `models-scout` runs this every 6 h. On a team Cloud machine (no Mac needs to be awake):
#   cmux automation create models-scout --command 'bash scripts/models/run-scout.sh' \
#     --repo manaflow-ai/cmux --ref feat-cmux-next --every 6h --timeout 20m --catch-up latest --target cloud
#   cmux automation secret set models-scout NAME --target cloud   # each name scout.ts lists
# The Cloud runner fetches the newest feat-cmux-next into its own checkout before each run. On a Mac's
# runner (--command 'bash ~/cmux-worktrees/models-scout/scripts/models/run-scout.sh'), this script moves
# its own worktree (named models-scout, never a shared checkout) to the newest feat-cmux-next instead.
# Exit codes are the scout's: 0 ok, 3 a failed check (the runner shows and notifies it), 1 a crash.
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
# A fresh Cloud machine may have no Bun: install the version CI pins, once, into ~/.bun.
if ! command -v bun >/dev/null 2>&1; then
  echo "installing bun 1.4.4 into ~/.bun" >&2
  curl -fsSL https://bun.sh/install | bash -s "bun-v1.4.4" >/dev/null || { echo "bun install failed" >&2; exit 1; }
fi
exec bun "$here/scripts/models/scout.ts" "$@"
