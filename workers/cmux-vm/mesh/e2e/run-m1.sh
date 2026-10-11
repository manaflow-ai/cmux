#!/usr/bin/env bash
# Mesh proof launcher (M1c cx-0op.3, M2 cx-0op.4, M3 cx-0op.5, M4 cx-0op.6). Runs e2e.ts (or the script
# named by the second argument, e.g. m3.ts or m4.ts) on cmux-lawrence-2 (userspace only,
# no sudo). The provider key file is never read here: the shell redirects it
# into ssh's stdin, and e2e.ts holds it in memory only.
#   workers/cmux-vm/mesh/e2e/run-m1.sh <exact feat-cmux-next sha> [e2e.ts|m3.ts|m4.ts]
set -euo pipefail
SHA="${1:?exact commit sha}"
SCRIPT="${2:-e2e.ts}"
case "$SCRIPT" in e2e.ts|m3.ts|m4.ts) ;; *) echo "unknown proof script $SCRIPT" >&2; exit 2 ;; esac
HOST="${MESH_HOST:-cmux-lawrence-2}"
KEY_FILE="${MESH_KEY_FILE:-$HOME/.secrets/freestyle-cmux-next-dev-20261004.key}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ssh "$HOST" "set -e; mkdir -p ~/cmux-agent-work/mesh-m1c && cd ~/cmux-agent-work/mesh-m1c
  [ -d repo ] || git clone -q --filter=blob:none --no-checkout https://github.com/manaflow-ai/cmux.git repo
  cd repo && git sparse-checkout set --no-cone /workers/cmux-vm/ >/dev/null && git fetch -q origin $SHA && git checkout -q --detach $SHA
  cd workers/cmux-vm && PATH=\$HOME/.bun/bin:/opt/homebrew/bin:\$PATH bun install --frozen-lockfile >/dev/null
  cd mesh/agent && PATH=\$HOME/.cargo/bin:/opt/homebrew/bin:\$PATH cargo build --release --locked 2>&1 | tail -1"
set +e
ssh "$HOST" "cd ~/cmux-agent-work/mesh-m1c/repo/workers/cmux-vm/mesh/e2e && PATH=\$HOME/.bun/bin:/opt/homebrew/bin:\$PATH bun $SCRIPT ../agent/target/release/cmux-mesh-agent" < "$KEY_FILE"
rc=$?
set -e
mkdir -p "$HERE/evidence"
rsync -a --exclude "*.key" --exclude "mesh*.json" "$HOST:cmux-agent-work/mesh-m1c/repo/workers/cmux-vm/mesh/e2e/out/" "$HERE/evidence/"
exit $rc
