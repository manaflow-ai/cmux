#!/bin/sh
# Builds the React agent pane (webviews/src/agent-session/acpmux) into the page
# that CmuxNextAgentPane ships as a module resource: index.html (markup, styles
# and the modulepreload links of its first load), its entry app-<hash>.js and
# chunks/ (code it loads when used: shiki's grammars, KaTeX), highlight-worker.js,
# image-worker.js and locales/ (strings and the loader that picks them). The page runs no inline
# script (CSP script-src 'self' plus the shared chunk origin), so markup an agent
# gets rendered cannot run script. The output is build output (gitignored;
# scripts/cmux-next/build-web-bundles.sh builds it before every app build).
#
# The pane's script comes from the React pages' build (build-pages-web.sh,
# webviews/scripts/pages/build-pages.mjs --agent-pane), as Chrome builds its New Tab
# page against chrome://resources like every WebUI page: React is the shared library
# the pages also import, from cmux-page://cmux.shared/ (Resources/pages/_shared); the
# rest of the pane is its own. The pane and the pages therefore build together:
#
#   scripts/cmux-next/build-agent-pane-web.sh          # rebuild the pane and the pages in the tree
#   scripts/cmux-next/build-agent-pane-web.sh --check  # build both into a temp dir only (the sources build)
#   scripts/cmux-next/build-agent-pane-web.sh --out DIR --pages-out PAGES
#                                                      # the pane into DIR, the pages and their shared chunks into PAGES
#
# build-pages-web.sh runs it to write the pane's page around the build's output:
#
#   scripts/cmux-next/build-agent-pane-web.sh --scripts DIR --pages-tree TREE --out DIR
#
# DIR holds the pane's app-<hash>.js, chunks/ and preload.html (build-pages.mjs
# --agent-pane), TREE the build's pages tree (TREE/_shared).
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SRC="$ROOT/webviews/src/agent-session"
OUT=""
PAGES_OUT=""
SCRIPTS=""
PAGES_TREE=""
CHECK=0
absolute() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --out|--pages-out|--scripts|--pages-tree)
      [ $# -ge 2 ] || { echo "error: $1 needs a directory" >&2; exit 2; }
      case "$1" in
        --out) OUT="$(absolute "$2")" ;;
        --pages-out) PAGES_OUT="$(absolute "$2")" ;;
        --scripts) SCRIPTS="$(absolute "$2")" ;;
        --pages-tree) PAGES_TREE="$(absolute "$2")" ;;
      esac
      shift ;;
    *) echo "usage: $0 [--check] [--out DIR --pages-out PAGES] | --scripts DIR --pages-tree TREE --out DIR" >&2; exit 2 ;;
  esac
  shift
done

# The pane's script comes from the pages' run: build both there.
if [ -z "$SCRIPTS" ]; then
  [ -z "$PAGES_TREE" ] || { echo "error: --pages-tree goes with --scripts" >&2; exit 2; }
  if [ "$CHECK" = 1 ]; then
    exec "$ROOT/scripts/cmux-next/build-pages-web.sh" --check
  fi
  # Both or neither: the pane imports the pages' shared library (cmux-page://cmux.shared/), and
  # build-pages-web.sh --out alone writes no pane.
  if [ -n "$OUT" ] && [ -z "$PAGES_OUT" ]; then
    echo "error: --out needs --pages-out: the pane imports the pages' shared library (cmux-page://cmux.shared/)" >&2
    exit 2
  fi
  if [ -n "$PAGES_OUT" ] && [ -z "$OUT" ]; then
    echo "error: --pages-out needs --out: it names where the pane's pages go, not the pane" >&2
    exit 2
  fi
  if [ -n "$OUT" ]; then
    exec "$ROOT/scripts/cmux-next/build-pages-web.sh" --out "$PAGES_OUT" --agent-pane "$OUT"
  fi
  exec "$ROOT/scripts/cmux-next/build-pages-web.sh"
fi

if [ -z "$PAGES_TREE" ] || [ -z "$OUT" ]; then
  echo "error: --scripts needs --pages-tree and --out" >&2
  exit 2
fi
if [ "$CHECK" = 1 ] || [ -n "$PAGES_OUT" ]; then
  echo "error: --scripts takes no --check or --pages-out" >&2
  exit 2
fi
ENTRY="$(cd "$SCRIPTS" && ls app-*.js)"
case "$ENTRY" in
  *[!A-Za-z0-9._-]*|"") echo "error: $SCRIPTS must hold one app-<hash>.js (build-pages.mjs --agent-pane)" >&2; exit 1 ;;
esac
[ -f "$SCRIPTS/preload.html" ] || { echo "error: $SCRIPTS has no preload.html (build-pages.mjs --agent-pane)" >&2; exit 1; }

command -v bun >/dev/null 2>&1 || { echo "error: bun is required to build the agent pane" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null

# The pane's strings (acpmux/Localizable.xcstrings -> generated/strings.json, build output, which
# build-pages-web.sh's gen-strings run wrote before the bundle). The bundle does not inline them:
# they ship as locales/<code>.js beside index.html, and the <head> loader runs English plus the
# app's language synchronously, before the module (no frame of English, no fetch before first
# paint). The loader is a file too (locales/loader.js).
LOADER="$(bun scripts/pages/split-strings.mjs "$SRC/acpmux/generated/strings.json" "$WORK/page/locales" __cmuxPaneStrings --loader-file)"

# --css-inputs lists the stylesheets the pane imports; the bundle drops them, so each must be
# one of the sheets the page's <style> is written from (checked below). The list only: the pane's
# script is the pages run's.
bun scripts/agent-pane/bundle.mjs "$SRC/acpmux/main.tsx" "$SRC/acpmux/shiki" "$WORK/pane/pane.js" --split --css-inputs "$WORK/imported-sheets" --css-inputs-only
# Code highlighting runs in a worker beside the page (conversation/highlightPool.ts): Pierre's
# worker, bundled with the same trimmed shiki. It is the entry point itself because the package
# marks the module side-effect free, so an import of it would be dropped. Both hosts serve it
# with a policy that allows no network.
bun scripts/agent-pane/bundle.mjs node_modules/@pierre/diffs/dist/worker/worker.js "$SRC/acpmux/shiki" "$WORK/page/highlight-worker.js"
# An attached image's decode, scale and encode run in a worker beside the page too
# (composer/imagePool.ts), so pasting large screenshots never blocks typing.
bun scripts/agent-pane/bundle.mjs "$SRC/acpmux/composer/imageWorker.ts" - "$WORK/page/image-worker.js"

# The page's sheets, derived, never a hand-kept list here (a sheet missing from one shipped its
# component unstyled in the app only, and five times this month failed every app build at the check
# below): every sheet the dev server applies, in its order. dev.tsx (the dev server's entry) imports
# the base sheets in the page's order, then main.tsx, whose components import the rest; bundle.mjs
# lists them depth-first as the modules run (cssInImportOrder). A new sheet a component imports
# ships with no change here, after the base sheets, and the app and the dev server agree.
bun scripts/agent-pane/bundle.mjs "$SRC/acpmux/dev.tsx" "$SRC/acpmux/shiki" "$WORK/order/dev.js" --split --css-inputs "$WORK/page-sheets" --css-inputs-only
# A sheet's own @import never loads here (mid-sheet, and the CSP loads no style file): the walk
# lists an imported local sheet before its importer, and Tailwind's import is compiled last below.
strip_imports() { perl -ne 'print unless /^\@import /' "$1"; }
: > "$WORK/styles.css"
while IFS= read -r sheet; do
  case "$sheet" in src/agent-session/acpmux/tailwind.css) continue ;; esac
  strip_imports "$ROOT/webviews/$sheet" >> "$WORK/styles.css"
done < "$WORK/page-sheets"
# Every sheet the pane imports ships (main.tsx's list against the page): dev.tsx imports main.tsx,
# so this holds unless the dev entry stops loading the pane.
while IFS= read -r sheet; do
  strip_imports "$ROOT/webviews/$sheet" > "$WORK/one.css"
  perl -0777 -e 'open my $all, "<", shift or die; open my $one, "<", shift or die; exit(index(<$all>, <$one>) < 0)' \
    "$WORK/styles.css" "$WORK/one.css" && continue
  echo "error: the agent pane imports webviews/$sheet but the page's styles (dev.tsx's sheets) leave it out" >&2
  exit 1
done < "$WORK/imported-sheets"
if grep -n '^@import ' "$WORK/styles.css" >&2; then
  echo "error: an @import reached the agent pane's styles, where it never loads; inline the sheet in build-agent-pane-web.sh" >&2
  exit 1
fi
# Tailwind utilities last (acpmux/tailwind.css): compiled over the classes the pane's sources use.
bun scripts/agent-pane/tailwind-css.mjs "$SRC/acpmux/tailwind.css" >> "$WORK/styles.css"

# Same-origin script files and the shared library only (no inline script, no eval; WebAssembly
# compiles for Ondine's Mermaid diagrams) and inline style. No connection of its own: the host's
# native transport (AgentPaneTransport) carries acpmux. No remote loads. Frames show only loopback
# web pages (a turn's preview card; URL+AgentPanePreview.swift keeps the same hosts) and the render
# frame (a render card; AgentPaneRenderFrame.swift). The page host sends the same script-src as a
# header (PageDescriptor.agent, test/fixtures/agent-page-csp.txt); a meta policy can only narrow it.
CSP="default-src 'none'; script-src 'self' cmux-page://cmux.shared 'wasm-unsafe-eval'; style-src 'unsafe-inline'; img-src data:; media-src 'self'; font-src data:; connect-src 'none'; frame-src cmux-page://cmux.agent/__render/frame http://localhost:* http://127.0.0.1:* https://localhost:* https://127.0.0.1:*"

{
  printf '<!doctype html>\n<html lang="en">\n<head>\n'
  printf '<meta charset="utf-8" />\n'
  printf '<meta http-equiv="Content-Security-Policy" content="%s" />\n' "$CSP"
  printf '<meta name="viewport" content="width=device-width, initial-scale=1" />\n'
  printf '<title>cmux Agent</title>\n'
  # The entry, its chunks and the shared library its first frame runs, fetched in parallel with the parse.
  cat "$SCRIPTS/preload.html"
  printf '%s\n' "$LOADER"
  printf '<style>\n'
  cat "$WORK/styles.css"
  printf '\n</style>\n</head>\n<body>\n<main id="root"></main>\n<script type="module" src="%s"></script>\n</body>\n</html>\n' "$ENTRY"
} | perl -pe 's/[ \t]+$//' > "$WORK/page/index.html"

# KaTeX's rules and fonts load with KaTeX, only when a reply draws math (conversation/Math.tsx,
# katexStylePlugin.mjs): never in the page's first <style>, always in a chunk.
if grep -q 'KaTeX_Main' "$WORK/page/index.html"; then
  echo "error: KaTeX's stylesheet reached the page's <style>; it loads with KaTeX (katexStylePlugin.mjs)" >&2
  exit 1
fi
if ! grep -lq 'KaTeX_Main' "$SCRIPTS"/chunks/*.js; then
  echo "error: no chunk carries KaTeX's stylesheet (katexStylePlugin.mjs)" >&2
  exit 1
fi

cp "$SCRIPTS/$ENTRY" "$WORK/page/$ENTRY"
cp -R "$SCRIPTS/chunks" "$WORK/page/chunks"
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -R "$WORK/page" "$OUT"
# Every script, preload and import of the page resolves: its own files on cmux.agent, the library on cmux.shared.
bun scripts/pages/build-pages.mjs --out "$PAGES_TREE" --agent-pane "$OUT" --check-only
echo "wrote $OUT/index.html ($(wc -c < "$OUT/index.html" | tr -d ' ') bytes), $ENTRY ($(wc -c < "$OUT/$ENTRY" | tr -d ' ') bytes) and $(ls "$OUT/chunks" | wc -l | tr -d ' ') chunks"
