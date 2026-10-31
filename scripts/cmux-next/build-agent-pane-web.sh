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
# An attached image's decode, scale and encode run in a worker beside the page too
# (composer/imagePool.ts), so pasting large screenshots never blocks typing.
bun scripts/agent-pane/bundle.mjs "$SRC/acpmux/composer/imageWorker.ts" - "$WORK/image-worker.js"

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
cp "$WORK/image-worker.js" "$OUT/image-worker.js"
rm -rf "$OUT/locales"
cp -R "$WORK/locales" "$OUT/locales"
echo "wrote $OUT/index.html ($(wc -c < "$OUT/index.html" | tr -d ' ') bytes) pane.js ($(wc -c < "$OUT/pane.js" | tr -d ' ') bytes) and $(ls "$OUT/chunks" | wc -l | tr -d ' ') chunks"
