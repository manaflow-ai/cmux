#!/bin/sh
# Builds the React agent pane (webviews/src/agent-session/acpmux) into the page
# that CmuxNextAgentPane ships as a module resource: index.html (markup and
# styles), pane.js (the app) and locales/ (strings and the loader that picks
# them). The page runs no inline script (CSP script-src 'self'), so markup an
# agent gets rendered cannot run script. The output is build output (gitignored;
# scripts/cmux-next/build-web-bundles.sh runs this before every app build).
#
#   scripts/cmux-next/build-agent-pane-web.sh          # rebuild the resource
#   scripts/cmux-next/build-agent-pane-web.sh --check  # build into a temp dir only (the sources build)
#   scripts/cmux-next/build-agent-pane-web.sh --out DIR  # build into DIR
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SRC="$ROOT/webviews/src/agent-session"
OUT="$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
MODE=build
# --out DIR writes the page into DIR instead (build-web-bundles.sh --out-root, checks).
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=--check ;;
    --out)
      [ $# -ge 2 ] || { echo "error: --out needs a directory" >&2; exit 2; }
      case "$2" in /*) OUT="$2" ;; *) OUT="$PWD/$2" ;; esac
      shift ;;
    *) echo "usage: $0 [--check] [--out DIR]" >&2; exit 2 ;;
  esac
  shift
done

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
bun scripts/pages/gen-strings.mjs --check agentPane
LOADER="$(bun scripts/pages/split-strings.mjs "$SRC/acpmux/generated/strings.json" "$WORK/locales" __cmuxPaneStrings --loader-file)"

# `shiki` resolves to a trimmed copy (acpmux/shiki): the JavaScript regex engine and
# common languages, not every grammar and the WebAssembly engine. The React Compiler
# runs on first-party sources, as in the Vite dev server; skipped components are listed.
bun scripts/agent-pane/bundle.mjs "$SRC/acpmux/main.tsx" "$SRC/acpmux/shiki" "$WORK/app.js"
# Code highlighting runs in a worker beside the page (conversation/highlightPool.ts): Pierre's
# worker, bundled with the same trimmed shiki. It is the entry point itself because the package
# marks the module side-effect free, so an import of it would be dropped. Both hosts serve it
# with a policy that allows no network.
bun scripts/agent-pane/bundle.mjs node_modules/@pierre/diffs/dist/worker/worker.js "$SRC/acpmux/shiki" "$WORK/highlight-worker.js"

# The desktop layer first (R139): chrome never selects, so Cmd-A highlights only
# fields and `.selectable` content. desktop.ts imports it, but the bundle drops CSS.
cat "$ROOT/webviews/src/pages/shared/desktop.css" > "$WORK/styles.css"
# The shared stylesheet opens with a Tailwind @import that only Vite resolves;
# the pane needs just its variables and rules, so drop @import lines.
grep -v '^@import ' "$SRC/shared/styles.css" >> "$WORK/styles.css"
# KaTeX's rules and fonts (data URLs: the CSP below allows fonts only from data:) for the
# transcript's math (conversation/Math.tsx).
bun scripts/agent-pane/katex-css.mjs >> "$WORK/styles.css"
# One surface for every menu and popover (the pane does not load ui.css, which imports it).
cat "$ROOT/webviews/src/ui/popupSurface.css" >> "$WORK/styles.css"
cat "$SRC/acpmux/styles.css" "$SRC/acpmux/conversation/conversation.css" "$SRC/acpmux/chips/chips.css" "$SRC/acpmux/previewCard/previewCard.css" "$SRC/acpmux/changes/changes.css" \
  "$SRC/acpmux/handoff/styles.css" "$SRC/acpmux/checkpoints/styles.css" "$SRC/acpmux/composerControls.css" "$SRC/acpmux/composerStates.css" "$SRC/acpmux/composerLocation.css" "$SRC/acpmux/composerAttachments.css" "$SRC/acpmux/markdownField.css" \
  "$SRC/acpmux/modelPicker.css" "$SRC/acpmux/keys.css" "$SRC/acpmux/summary/summary.css" "$SRC/acpmux/subagents/subagents.css" "$SRC/acpmux/header/header.css" "$SRC/acpmux/newtab/screen.css" "$SRC/acpmux/threadMinimap/threadMinimap.css" >> "$WORK/styles.css"
cat "$SRC/acpmux/turnChanges/turnChanges.css" "$SRC/acpmux/Inspector.css" >> "$WORK/styles.css"

# Same-origin script files only (no inline script, no eval) and inline style. No connection of its own: the
# host's native transport (AgentPaneTransport) carries acpmux. No remote loads. Frames show only loopback web
# pages (a turn's preview card; URL+AgentPanePreview.swift keeps the same hosts) and the render frame
# (a render card; AgentPaneRenderFrame.swift). The page host sends the same
# script-src (PageDescriptor.agent, test/fixtures/agent-page-csp.txt).
CSP="default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src data:; media-src 'self'; font-src data:; connect-src 'none'; frame-src cmux-agent://render http://localhost:* http://127.0.0.1:* https://localhost:* https://127.0.0.1:*"

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
  echo "agent pane web bundle builds"
  exit 0
fi

mkdir -p "$OUT"
cp "$WORK/index.html" "$OUT/index.html"
cp "$WORK/pane.js" "$OUT/pane.js"
cp "$WORK/highlight-worker.js" "$OUT/highlight-worker.js"
rm -rf "$OUT/locales"
cp -R "$WORK/locales" "$OUT/locales"
echo "wrote $OUT/index.html ($(wc -c < "$OUT/index.html" | tr -d ' ') bytes) and pane.js ($(wc -c < "$OUT/pane.js" | tr -d ' ') bytes)"
