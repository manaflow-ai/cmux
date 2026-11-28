#!/usr/bin/env bash
# remote.sh <command...>: sync this worktree's mobile-next tree (and the shared
# packages it uses) to the build mini, then run the command there in
# ~/cnm/src/mobile-next. Build host: $CNM_HOST (default mini-cmux8s-mac-mini).
set -euo pipefail
HOST="${CNM_HOST:-mini-cmux8s-mac-mini}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ssh "$HOST" 'mkdir -p ~/cnm/src/Packages/Shared'
rsync -az --delete --exclude .build --exclude node_modules --exclude DerivedData --exclude '*.xcodeproj' \
  --exclude artifacts --exclude .wrangler "$ROOT/mobile-next/" "$HOST:cnm/src/mobile-next/"
for pkg in CmuxGhosttyKit CmuxTheme CMUXMobileCore; do
  rsync -az --delete --exclude .build "$ROOT/Packages/Shared/$pkg/" "$HOST:cnm/src/Packages/Shared/$pkg/"
done
[[ $# -eq 0 ]] && exit 0
ssh "$HOST" "cd ~/cnm/src/mobile-next && export PATH=/opt/homebrew/bin:\$HOME/.local/bin:\$PATH && $*"
