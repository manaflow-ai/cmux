#!/bin/sh
# Builds the agent pane PROTOTYPE ported from codex-atlas-clone
# (webviews/src/agent-session-port) into one self-contained index.html that
# CmuxNextAgentPane ships next to the current pane. Debug Settings
# (agentPane.prototype = Port) makes new agent tabs load it. The output is
# committed; rerun this after changing the TypeScript sources.
#
#   scripts/cmux-next/build-agent-pane-port-web.sh          # rebuild the resource
#   scripts/cmux-next/build-agent-pane-port-web.sh --check  # fail if it is stale
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT="$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/port"
MODE="${1:-build}"

command -v bun >/dev/null 2>&1 || { echo "error: bun is required to build the agent pane" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null
node scripts/agent-pane-port/bundle.mjs "$WORK/index.html"
perl -pi -e 's/[ \t]+$//' "$WORK/index.html"

if [ "$MODE" = "--check" ]; then
  if ! cmp -s "$WORK/index.html" "$OUT/index.html"; then
    echo "error: $OUT/index.html is stale; run scripts/cmux-next/build-agent-pane-port-web.sh" >&2
    exit 1
  fi
  echo "agent pane port web bundle is current"
  exit 0
fi

mkdir -p "$OUT"
cp "$WORK/index.html" "$OUT/index.html"
echo "wrote $OUT/index.html ($(wc -c < "$OUT/index.html" | tr -d ' ') bytes)"
