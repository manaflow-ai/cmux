#!/bin/sh
# Fleet confirming run of the remote-floor probes against the real model
# through the team subrouter. Scratch HOME and npm prefix under a temp dir,
# removed at the end; only fixture files act as secrets.
set -u
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/remote-floor-fleet.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
version=${CLAUDE_PROBE_VERSION:-2.1.289}
url=${CLAUDE_PROBE_MODEL_URL:-http://100.89.225.106:31415}
echo "host $(hostname) claude $version model $url"
ls "/Library/Application Support/ClaudeCode/" 2>/dev/null | sed 's/^/managed: /'
(cd "$scratch" && HOME="$scratch" npm install --silent --no-audit --no-fund --prefix "$scratch/npm" \
  "@anthropic-ai/claude-code@$version" >/dev/null 2>&1) || { echo "npm install failed"; exit 2; }
TMPDIR="$scratch" python3 "$here/probe_claude.py" --claude "$scratch/npm/node_modules/.bin/claude" \
  --real-model "$url" "$@"
