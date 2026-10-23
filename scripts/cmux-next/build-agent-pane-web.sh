#!/bin/sh
# Builds the React agent pane (webviews/src/agent-session/acpmux) into the page
# that CmuxNextAgentPane ships as a module resource: index.html (markup and
# styles), pane.js (the app), chunks/ (code it loads when used) and locales/
# (strings and the loader that picks them). The page runs no inline script
# (CSP script-src 'self'), so markup an agent gets rendered cannot run
# script. The output is build output (gitignored;
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

# The pane's strings (acpmux/Localizable.xcstrings -> generated/strings.json, build output). The
# bundle does not inline them: they ship as locales/<code>.js beside index.html, and the <head>
# loader runs English plus the app's language synchronously, before the module (no frame of
# English, no fetch before first paint). The loader is a file too (locales/loader.js).
bun scripts/pages/gen-strings.mjs agentPane
LOADER="$(bun scripts/pages/split-strings.mjs "$SRC/acpmux/generated/strings.json" "$WORK/locales" __cmuxPaneStrings --loader-file)"

# `shiki` resolves to a trimmed copy (acpmux/shiki): the JavaScript regex engine and
# common languages, not every grammar and the WebAssembly engine. The React Compiler
# runs on first-party sources, as in the Vite dev server; skipped components are listed.
# Dynamic imports (shiki's grammars, KaTeX) become chunks/ beside pane.js, loaded when used.
# --css-inputs lists the stylesheets the pane imports; the bundle drops them, so each must be
# one of the sheets the page's <style> is written from (checked below).
bun scripts/agent-pane/bundle.mjs "$SRC/acpmux/main.tsx" "$SRC/acpmux/shiki" "$WORK/pane/pane.js" --split --css-inputs "$WORK/imported-sheets"
# Code highlighting runs in a worker beside the page (conversation/highlightPool.ts): Pierre's
# worker, bundled with the same trimmed shiki. It is the entry point itself because the package
# marks the module side-effect free, so an import of it would be dropped. Both hosts serve it
# with a policy that allows no network.
bun scripts/agent-pane/bundle.mjs node_modules/@pierre/diffs/dist/worker/worker.js "$SRC/acpmux/shiki" "$WORK/highlight-worker.js"

# The desktop layer first (R139): chrome never selects, so Cmd-A highlights only
# fields and `.selectable` content. desktop.ts imports it, but the bundle drops CSS.
cat "$ROOT/webviews/src/pages/shared/desktop.css" > "$WORK/styles.css"
# The liquid glass surface and tokens, which desktop.ts imports beside desktop.css.
cat "$ROOT/webviews/src/ui/glass/glass.css" >> "$WORK/styles.css"
# The shared shimmer wave, which desktop.ts imports too.
cat "$ROOT/webviews/src/ui/wave.css" >> "$WORK/styles.css"
# The shared stylesheet opens with a Tailwind @import that only Vite resolves;
# the pane needs just its variables and rules, so drop @import lines.
grep -v '^@import ' "$SRC/shared/styles.css" >> "$WORK/styles.css"
# One surface for every menu and popover (the pane does not load ui.css, which imports it).
cat "$ROOT/webviews/src/ui/popupSurface.css" >> "$WORK/styles.css"
# The shared icon+label button (New Tab's tools, the composer footer), imported by main.tsx.
cat "$ROOT/webviews/src/ui/ghost.css" >> "$WORK/styles.css"
# The shared find pill (Find in Chat), imported by ui/FindPill.tsx.
cat "$ROOT/webviews/src/ui/findPill.css" >> "$WORK/styles.css"
# The import suggestion cards in New Tab's notice slot (ui/ImportCards.tsx).
cat "$ROOT/webviews/src/ui/importCards.css" >> "$WORK/styles.css"
cat "$ROOT/webviews/src/theme/messages.css" "$SRC/acpmux/styles.css" "$SRC/acpmux/conversation/conversation.css" "$SRC/acpmux/chips/chips.css" "$SRC/acpmux/chips/linkCard.css" "$SRC/acpmux/previewCard/previewCard.css" "$SRC/acpmux/contextCard.css" >> "$WORK/styles.css"
# changes.css @imports git.css; an @import never loads here (mid-sheet, and the CSP loads no
# style file), so inline it where the import stood.
cat "$SRC/acpmux/changes/git.css" >> "$WORK/styles.css"
grep -v '^@import ' "$SRC/acpmux/changes/changes.css" >> "$WORK/styles.css"
cat "$SRC/acpmux/handoff/styles.css" "$SRC/acpmux/checkpoints/styles.css" "$SRC/acpmux/composerControls.css" "$SRC/acpmux/composerStates.css" "$SRC/acpmux/composerLocation.css" "$SRC/acpmux/composerLook.css" "$SRC/acpmux/savedEnvironments.css" "$SRC/acpmux/bottomStack.css" "$SRC/acpmux/composerAttachments.css" "$SRC/acpmux/composer/dropOverlay.css" "$SRC/acpmux/markdownField.css" \
  "$SRC/acpmux/modelPicker.css" "$SRC/acpmux/keys.css" "$SRC/acpmux/summary/summary.css" "$SRC/acpmux/subagents/subagents.css" "$SRC/acpmux/header/header.css" "$SRC/acpmux/needsYou/needsYou.css" "$SRC/acpmux/newtab/screen.css" "$SRC/acpmux/newtab/history.css" "$SRC/acpmux/newtab/noEntry.css" "$SRC/acpmux/threadMinimap/threadMinimap.css" >> "$WORK/styles.css"
cat "$SRC/acpmux/turnChanges/turnChanges.css" "$SRC/acpmux/Inspector.css" "$SRC/acpmux/inspector/inspector.css" "$SRC/acpmux/inspector/ContextSection.css" "$SRC/acpmux/dictation.css" >> "$WORK/styles.css"
cat "$SRC/acpmux/addProject.css" "$SRC/acpmux/harnesses/harnesses.css" "$SRC/acpmux/replay/replay.css" "$SRC/acpmux/offer/suggestedTasks.css" "$SRC/acpmux/started/startedSessions.css" "$SRC/acpmux/started/sessionHover.css" "$SRC/acpmux/conversation/SubsessionCallCard.css" "$SRC/acpmux/conversation/AgentMessageRow.css" "$ROOT/webviews/src/markdown-task-checkbox.css" >> "$WORK/styles.css"
# Every sheet the pane imports ships: a missing one renders its component unstyled in the app
# only (the dev server loads imports), as New Tab's tools did.
while IFS= read -r sheet; do
  perl -0777 -e 'open my $all, "<", shift or die; open my $one, "<", shift or die; exit(index(<$all>, <$one>) < 0)' \
    "$WORK/styles.css" "$ROOT/webviews/$sheet" && continue
  echo "error: the agent pane imports webviews/$sheet but build-agent-pane-web.sh does not add it to the page's styles" >&2
  exit 1
done < "$WORK/imported-sheets"
if grep -n '^@import ' "$WORK/styles.css" >&2; then
  echo "error: an @import reached the agent pane's styles, where it never loads; inline the sheet in build-agent-pane-web.sh" >&2
  exit 1
fi
# Tailwind utilities last (acpmux/tailwind.css): compiled over the classes the pane's sources use.
bun scripts/agent-pane/tailwind-css.mjs "$SRC/acpmux/tailwind.css" >> "$WORK/styles.css"

# Same-origin script files only (no inline script, no eval; WebAssembly compiles for Ondine's Mermaid diagrams) and inline style. No connection of its own: the
# host's native transport (AgentPaneTransport) carries acpmux. No remote loads. Frames show only loopback web
# pages (a turn's preview card; URL+AgentPanePreview.swift keeps the same hosts) and the render frame
# (a render card; AgentPaneRenderFrame.swift). The page host sends the same
# script-src (PageDescriptor.agent, test/fixtures/agent-page-csp.txt).
CSP="default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'unsafe-inline'; img-src data:; media-src 'self'; font-src data:; connect-src 'none'; frame-src cmux-agent://render http://localhost:* http://127.0.0.1:* https://localhost:* https://127.0.0.1:*"

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

# KaTeX's rules and fonts load with KaTeX, only when a reply draws math (conversation/Math.tsx,
# katexStylePlugin.mjs): never in the page's first <style>, always in a chunk.
if grep -q 'KaTeX_Main' "$WORK/index.html"; then
  echo "error: KaTeX's stylesheet reached the page's <style>; it loads with KaTeX (katexStylePlugin.mjs)" >&2
  exit 1
fi
if ! grep -lq 'KaTeX_Main' "$WORK"/pane/chunks/*.js; then
  echo "error: no chunk carries KaTeX's stylesheet (katexStylePlugin.mjs)" >&2
  exit 1
fi

if [ "$MODE" = "--check" ]; then
  echo "agent pane web bundle builds"
  exit 0
fi

mkdir -p "$OUT"
cp "$WORK/index.html" "$OUT/index.html"
cp "$WORK/pane/pane.js" "$OUT/pane.js"
rm -rf "$OUT/chunks"
cp -R "$WORK/pane/chunks" "$OUT/chunks"
cp "$WORK/highlight-worker.js" "$OUT/highlight-worker.js"
rm -rf "$OUT/locales"
cp -R "$WORK/locales" "$OUT/locales"
echo "wrote $OUT/index.html ($(wc -c < "$OUT/index.html" | tr -d ' ') bytes) pane.js ($(wc -c < "$OUT/pane.js" | tr -d ' ') bytes) and $(ls "$OUT/chunks" | wc -l | tr -d ' ') chunks"
