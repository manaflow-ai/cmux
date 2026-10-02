#!/bin/sh
# Builds the React agent pane (webviews/src/agent-session/acpmux) into one
# self-contained index.html that CmuxNextAgentPane ships as a module resource.
# The output is committed; rerun this after changing the TypeScript sources.
#
#   scripts/cmux-next/build-agent-pane-web.sh          # rebuild the resource
#   scripts/cmux-next/build-agent-pane-web.sh --check  # fail if it is stale
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SRC="$ROOT/webviews/src/agent-session"
OUT="$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
MODE="${1:-build}"

command -v bun >/dev/null 2>&1 || { echo "error: bun is required to build the agent pane" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null

# `shiki` resolves to a trimmed copy (acpmux/shiki): the JavaScript regex engine and
# common languages, not every grammar and the WebAssembly engine.
bun x esbuild "$SRC/acpmux/main.tsx" \
  --bundle \
  --format=esm \
  --platform=browser \
  --target=es2022 \
  '--define:process.env.NODE_ENV="production"' \
  --minify \
  --legal-comments=none \
  "--alias:shiki=$SRC/acpmux/shiki" \
  --log-level=warning \
  --outfile="$WORK/app.js"

# The shared stylesheet opens with a Tailwind @import that only Vite resolves;
# the pane needs just its variables and rules, so drop @import lines.
grep -v '^@import ' "$SRC/shared/styles.css" > "$WORK/styles.css"
cat "$SRC/acpmux/styles.css" "$SRC/acpmux/conversation/conversation.css" "$SRC/acpmux/changes/changes.css" \
  "$SRC/acpmux/composerControls.css" "$SRC/acpmux/searchChats.css" "$SRC/acpmux/markdownField.css" >> "$WORK/styles.css"

# Inline script and style, loopback WebSocket only. No remote loads, no eval.
CSP="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src ws://127.0.0.1:* ws://localhost:*"

{
  printf '<!doctype html>\n<html lang="en">\n<head>\n'
  printf '<meta charset="utf-8" />\n'
  printf '<meta http-equiv="Content-Security-Policy" content="%s" />\n' "$CSP"
  printf '<meta name="viewport" content="width=device-width, initial-scale=1" />\n'
  printf '<title>cmux Agent</title>\n<style>\n'
  cat "$WORK/styles.css"
  printf '\n</style>\n</head>\n<body>\n<main id="root"></main>\n<script type="module">\n'
  perl -0pe 's{</script}{<\\/script}ig; s{<!--}{<\\!--}g' "$WORK/app.js"
  printf '\n</script>\n</body>\n</html>\n'
} | perl -pe 's/[ \t]+$//' > "$WORK/index.html"

if [ "$MODE" = "--check" ]; then
  if ! cmp -s "$WORK/index.html" "$OUT/index.html"; then
    echo "error: $OUT/index.html is stale; run scripts/cmux-next/build-agent-pane-web.sh (after merging feat-cmux-next: scripts/cmux-next/regenerate-web-bundles.sh)" >&2
    exit 1
  fi
  echo "agent pane web bundle is current"
  exit 0
fi

mkdir -p "$OUT"
cp "$WORK/index.html" "$OUT/index.html"
echo "wrote $OUT/index.html ($(wc -c < "$OUT/index.html" | tr -d ' ') bytes)"
