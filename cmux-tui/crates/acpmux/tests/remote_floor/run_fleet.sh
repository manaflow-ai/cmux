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
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.bun/bin"
claude_bin=""
if command -v npm >/dev/null 2>&1; then
  if (cd "$scratch" && HOME="$scratch" npm install --no-audit --no-fund --prefix "$scratch/npm" \
    "@anthropic-ai/claude-code@$version" >"$scratch/npm.log" 2>&1); then
    claude_bin="$scratch/npm/node_modules/.bin/claude"
  else
    echo "npm install failed:"; tail -15 "$scratch/npm.log"
  fi
fi
if [ -z "$claude_bin" ]; then
  for candidate in $(command -v -a claude 2>/dev/null) "$HOME/.local/bin/claude" /opt/homebrew/bin/claude; do
    [ -x "$candidate" ] || continue
    echo "candidate $candidate: $("$candidate" --version 2>/dev/null)"
    case "$("$candidate" --version 2>/dev/null)" in "$version "*) claude_bin=$candidate ;; esac
  done
fi
[ -n "$claude_bin" ] || { echo "no claude $version on this host (no npm, no matching install)"; exit 2; }
echo "using $claude_bin"
TMPDIR="$scratch" python3 "$here/probe_claude.py" --claude "$claude_bin" \
  --real-model "$url" "$@"
