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
#   scripts/cmux-next/build-agent-pane-web.sh --styles FILE  # write only the page's styles to FILE
#   scripts/cmux-next/build-agent-pane-web.sh --sheets FILE  # list the files they come from, in order
#   scripts/cmux-next/build-agent-pane-web.sh --entry FILE ...  # build from another entry module
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SRC="$ROOT/webviews/src/agent-session"
OUT="$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
ENTRY="$SRC/acpmux/main.tsx"
MODE=build
STYLES=
SHEETS=
# --out DIR writes the page into DIR instead (build-web-bundles.sh --out-root, checks).
# --styles FILE writes just the page's <style> (no strings, script or page), for tests and tools
# that check what the pane ships; --sheets FILE writes the absolute paths of the files it comes
# from, in cascade order, acpmux/tailwind.css last (the gallery's pane stylesheet). --entry FILE
# bundles another entry module (a test's fixture that imports main.tsx and a sheet of its own).
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=--check ;;
    --out|--styles|--sheets|--entry)
      [ $# -ge 2 ] || { echo "error: $1 needs a path" >&2; exit 2; }
      case "$2" in /*) path="$2" ;; *) path="$PWD/$2" ;; esac
      case "$1" in --out) OUT="$path" ;; --styles) STYLES="$path" ;; --sheets) SHEETS="$path" ;; *) ENTRY="$path" ;; esac
      shift ;;
    *) echo "usage: $0 [--check] [--out DIR] [--styles FILE] [--sheets FILE] [--entry FILE]" >&2; exit 2 ;;
  esac
  shift
done

command -v bun >/dev/null 2>&1 || { echo "error: bun is required to build the agent pane" >&2; exit 1; }
"$ROOT/scripts/check-webviews-bun-version.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null

if [ -n "$STYLES$SHEETS" ]; then
  # Only the list of sheets: no React Compiler, no minify, nothing written (about a second).
  bun scripts/agent-pane/bundle.mjs "$ENTRY" "$SRC/acpmux/shiki" "$WORK/pane/pane.js" --split --css-inputs "$WORK/imported-sheets" --css-inputs-only
else
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
# --css-inputs lists the stylesheets the pane imports, in the order its modules load them; the
# bundle drops them, so the page's <style> is written from that list (below).
bun scripts/agent-pane/bundle.mjs "$ENTRY" "$SRC/acpmux/shiki" "$WORK/pane/pane.js" --split --css-inputs "$WORK/imported-sheets"
# Code highlighting runs in a worker beside the page (conversation/highlightPool.ts): Pierre's
# worker, bundled with the same trimmed shiki. It is the entry point itself because the package
# marks the module side-effect free, so an import of it would be dropped. Both hosts serve it
# with a policy that allows no network.
bun scripts/agent-pane/bundle.mjs node_modules/@pierre/diffs/dist/worker/worker.js "$SRC/acpmux/shiki" "$WORK/highlight-worker.js"
fi

# The page's styles, in cascade order. A sheet a module of the pane imports needs no line here: it
# comes from the bundle's list (bundle.mjs --css-inputs), in the order the modules load it.
# 1. The shared layers the pane builds on (webviews/src outside agent-session/), in import order:
#    desktop.css first (R139: chrome never selects, so Cmd-A highlights only fields and
#    `.selectable` content; main.tsx imports pages/shared/desktop first), then the liquid glass and
#    the wave that desktop.ts imports beside it, the ghost button, the find pill, ...
if [ "$(sed -n 1p "$WORK/imported-sheets")" != src/pages/shared/desktop.css ]; then
  echo "error: the agent pane's first stylesheet must be pages/shared/desktop.css (main.tsx imports pages/shared/desktop first)" >&2
  exit 1
fi
grep -v '^src/agent-session/' "$WORK/imported-sheets" > "$WORK/page-sheets" || true
# 2. Sheets no module of the pane imports (dev.tsx loads them for the dev server), in this order:
#    the shared stylesheet (its Tailwind @import, which only Vite resolves, is dropped), the one
#    surface for every menu and popover (the pane does not load ui.css, which imports it), then
#    the pane's base sheets. changes.css @imports git.css, which goes in just before it. A sheet
#    here that a module starts importing stays here (page-css.mjs writes a sheet once, first time).
cat >> "$WORK/page-sheets" <<'SHEETS'
src/agent-session/shared/styles.css
src/ui/popupSurface.css
src/agent-session/acpmux/styles.css
src/agent-session/acpmux/conversation/conversation.css
src/agent-session/acpmux/chips/chips.css
src/agent-session/acpmux/previewCard/previewCard.css
src/agent-session/acpmux/changes/changes.css
src/agent-session/acpmux/composerControls.css
src/agent-session/acpmux/composerStates.css
src/agent-session/acpmux/composerLocation.css
src/agent-session/acpmux/bottomStack.css
src/agent-session/acpmux/composerAttachments.css
src/agent-session/acpmux/modelPicker.css
src/agent-session/acpmux/keys.css
src/agent-session/acpmux/summary/summary.css
src/agent-session/acpmux/subagents/subagents.css
src/agent-session/acpmux/header/header.css
src/agent-session/acpmux/newtab/screen.css
src/agent-session/acpmux/newtab/history.css
src/agent-session/acpmux/threadMinimap/threadMinimap.css
src/agent-session/acpmux/turnChanges/turnChanges.css
SHEETS
# 3. The pane's own sheets its modules import, in import order, after the layers they build on.
grep '^src/agent-session/' "$WORK/imported-sheets" >> "$WORK/page-sheets" || true
# No @import reaches the page (mid-sheet the browser drops it, and the CSP loads no style file):
# page-css.mjs inlines a sheet's relative @import just before it and drops a package's.
if [ -n "$SHEETS" ]; then
  bun scripts/agent-pane/page-css.mjs --files "$WORK/page-sheets" > "$SHEETS"
  printf '%s\n' "$SRC/acpmux/tailwind.css" >> "$SHEETS"
  exit 0
fi
bun scripts/agent-pane/page-css.mjs "$WORK/page-sheets" > "$WORK/styles.css"
# Backstops. Every sheet the pane imports ships (its rules, less its own @import lines): a missing
# one renders its component unstyled in the app only (the dev server loads imports), as New Tab's
# tools did.
while IFS= read -r sheet; do
  perl -0777 -e 'open my $all, "<", shift or die; open my $one, "<", shift or die; my $css = <$one>; $css =~ s/^\@import [^\n]*\n?//mg; exit(index(<$all>, $css) < 0)' \
    "$WORK/styles.css" "$ROOT/webviews/$sheet" && continue
  echo "error: the agent pane imports webviews/$sheet but its rules are not in the page's styles (page-css.mjs)" >&2
  exit 1
done < "$WORK/imported-sheets"
if grep -n '^@import ' "$WORK/styles.css" >&2; then
  echo "error: an @import reached the agent pane's styles, where it never loads (page-css.mjs inlines relative ones)" >&2
  exit 1
fi
# Tailwind utilities last (acpmux/tailwind.css): compiled over the classes the pane's sources use.
bun scripts/agent-pane/tailwind-css.mjs "$SRC/acpmux/tailwind.css" >> "$WORK/styles.css"
if [ -n "$STYLES" ]; then
  cp "$WORK/styles.css" "$STYLES"
  exit 0
fi

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
