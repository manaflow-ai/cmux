#!/bin/sh
# Builds the React agent pane (webviews/src/agent-session/acpmux) into the page
# that CmuxNextAgentPane ships as a module resource: index.html (markup and
# styles), pane.js (the app) and locales/ (strings and the loader that picks
# them). The page runs no inline script (CSP script-src 'self'), so markup an
# agent gets rendered cannot run script. The output is committed; rerun this
# after changing the TypeScript sources.
#
#   scripts/cmux-next/build-agent-pane-web.sh          # rebuild the resource
#   scripts/cmux-next/build-agent-pane-web.sh --check  # fail if it is stale
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SRC="$ROOT/webviews/src/agent-session"
OUT="$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
MODE="${1:-build}"

command -v bun >/dev/null 2>&1 || { echo "error: bun is required to build the agent pane" >&2; exit 1; }
"$ROOT/scripts/check-webviews-bun-version.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null

# The pane's strings (acpmux/Localizable.xcstrings -> generated/strings.json) must be current. The
# bundle does not inline them: they ship as locales/<code>.js beside index.html, and the <head>
# loader runs English plus the app's language synchronously, before the module (no frame of
# English, no fetch before first paint). The loader is a file too (locales/loader.js).
node scripts/pages/gen-strings.mjs --check agentPane
LOADER="$(node scripts/pages/split-strings.mjs "$SRC/acpmux/generated/strings.json" "$WORK/locales" __cmuxPaneStrings --loader-file)"

# `shiki` resolves to a trimmed copy (acpmux/shiki): the JavaScript regex engine and
# common languages, not every grammar and the WebAssembly engine. The React Compiler
# runs on first-party sources, as in the Vite dev server; skipped components are listed.
bun scripts/agent-pane/bundle.mjs "$SRC/acpmux/main.tsx" "$SRC/acpmux/shiki" "$WORK/app.js"

# The desktop layer first (R139): chrome never selects, so Cmd-A highlights only
# fields and `.selectable` content. desktop.ts imports it, but the bundle drops CSS.
cat "$ROOT/webviews/src/pages/shared/desktop.css" > "$WORK/styles.css"
# The shared stylesheet opens with a Tailwind @import that only Vite resolves;
# the pane needs just its variables and rules, so drop @import lines.
grep -v '^@import ' "$SRC/shared/styles.css" >> "$WORK/styles.css"
# KaTeX's rules and fonts (data URLs: the CSP below allows fonts only from data:) for the
# transcript's math (conversation/Math.tsx).
node scripts/agent-pane/katex-css.mjs >> "$WORK/styles.css"
cat "$SRC/acpmux/styles.css" "$SRC/acpmux/conversation/conversation.css" "$SRC/acpmux/changes/changes.css" \
<<<<<<< HEAD
  "$SRC/acpmux/handoff/styles.css" "$SRC/acpmux/checkpoints/styles.css" "$SRC/acpmux/composerControls.css" "$SRC/acpmux/composerStates.css" "$SRC/acpmux/searchChats.css" "$SRC/acpmux/markdownField.css" \
  "$SRC/acpmux/modelPicker.css" "$SRC/acpmux/keys.css" "$SRC/acpmux/summary/summary.css" "$SRC/acpmux/header/header.css" "$SRC/acpmux/newtab/screen.css" >> "$WORK/styles.css"
=======
  "$SRC/acpmux/handoff/styles.css" "$SRC/acpmux/checkpoints/styles.css" "$SRC/acpmux/composerControls.css" "$SRC/acpmux/composerStates.css" "$SRC/acpmux/composerLocation.css" "$SRC/acpmux/searchChats.css" "$SRC/acpmux/markdownField.css" \
  "$SRC/acpmux/modelPicker.css" "$SRC/acpmux/keys.css" "$SRC/acpmux/summary/summary.css" "$SRC/acpmux/newtab/screen.css" >> "$WORK/styles.css"
>>>>>>> origin/feat-cmux-next

# Same-origin script files only (no inline script, no eval) and inline style. No connection of its own: the
# host's native transport (AgentPaneTransport) carries acpmux. No remote loads. Frames show only loopback web
# pages (a turn's preview card; URL+AgentPanePreview.swift keeps the same hosts). The page host sends the same
# script-src (PageDescriptor.agent, test/fixtures/agent-page-csp.txt).
CSP="default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; frame-src http://localhost:* http://127.0.0.1:* https://localhost:* https://127.0.0.1:*"

{
  printf '<!doctype html>\n<html lang="en">\n<head>\n'
  printf '<meta charset="utf-8" />\n'
  printf '<meta http-equiv="Content-Security-Policy" content="%s" />\n' "$CSP"
  printf '<meta name="viewport" content="width=device-width, initial-scale=1" />\n'
  printf '<title>cmux Agent</title>\n'
  printf '%s\n' "$LOADER"
  printf '<style>\n'
  cat "$WORK/styles.css"
  printf '\n</style>\n</head>\n<body>\n<main id="root"></main>\n<script type="module" src="pane.js"></script>\n</body>\n</html>\n'
} | perl -pe 's/[ \t]+$//' > "$WORK/index.html"
cp "$WORK/app.js" "$WORK/pane.js"

if [ "$MODE" = "--check" ]; then
  if ! cmp -s "$WORK/index.html" "$OUT/index.html" || ! cmp -s "$WORK/pane.js" "$OUT/pane.js" \
    || ! diff -rq "$WORK/locales" "$OUT/locales" >/dev/null 2>&1; then
    echo "error: $OUT/index.html is stale; run scripts/cmux-next/build-agent-pane-web.sh (after merging feat-cmux-next: scripts/cmux-next/regenerate-web-bundles.sh)" >&2
    exit 1
  fi
  echo "agent pane web bundle is current"
  exit 0
fi

mkdir -p "$OUT"
cp "$WORK/index.html" "$OUT/index.html"
cp "$WORK/pane.js" "$OUT/pane.js"
rm -rf "$OUT/locales"
cp -R "$WORK/locales" "$OUT/locales"
echo "wrote $OUT/index.html ($(wc -c < "$OUT/index.html" | tr -d ' ') bytes) and pane.js ($(wc -c < "$OUT/pane.js" | tr -d ' ') bytes)"
