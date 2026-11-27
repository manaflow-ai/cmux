#!/usr/bin/env bash
# Run one validation script on the WireGuard client host (default cmux-lawrence-2,
# macOS, userspace WireGuard only). The API key travels over SSH stdin into a
# 0600 file under a 0700 directory; it never appears on a command line.
#
#   ./run-remote.sh 05-stateful.ts            # run one script
#   ./run-remote.sh --key-remove              # delete the remote key file
set -euo pipefail
HOST="${MESH_HOST:-cmux-lawrence-2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY_FILE="${MESH_KEY_FILE:-$HOME/.secrets/freestyle-cmux-next-dev-20261004.key}"
RUN_ID="${MESH_RUN_ID:?set MESH_RUN_ID}"

if [[ "${1:-}" == "--key-remove" ]]; then
  ssh "$HOST" 'rm -f ~/mesh-validation/.key && echo removed'
  exit 0
fi
script="$1"; shift || true
ssh "$HOST" 'mkdir -p ~/mesh-validation && chmod 700 ~/mesh-validation'
# Only files Git tracks: an untracked .env, key or scratch file here never leaves
# this Mac (cx-44j.25). New scripts must be committed (or git add-ed) to run.
git -C "$HERE" ls-files -z --cached -- . \
  | rsync -a --from0 --files-from=- "$HERE/" "$HOST:mesh-validation/"
ssh "$HOST" 'test -x ~/mesh-validation/wgprobe/wgprobe || (cd ~/mesh-validation/wgprobe && PATH=/opt/homebrew/bin:$PATH go build -o wgprobe .)'
ssh "$HOST" 'test -s ~/mesh-validation/.key' || ssh "$HOST" 'umask 077; cat > ~/mesh-validation/.key' < "$KEY_FILE"
set +e
ssh "$HOST" "cd ~/mesh-validation && PATH=/opt/homebrew/bin:\$PATH MESH_KEY_FILE=\$HOME/mesh-validation/.key MESH_RUN_ID=$RUN_ID ${MESH_EXTRA_ENV:-} bun $script"
rc=$?
set -e
mkdir -p "$HERE/out"
rsync -a "$HOST:mesh-validation/out/" "$HERE/out/" --exclude keys
exit $rc
