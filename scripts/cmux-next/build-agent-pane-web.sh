#!/bin/sh
# Builds the React agent pane (webviews/src/agent-session/acpmux) into the page
# that CmuxNextAgentPane ships as a module resource: index.html (markup),
# pane.css (the styles; pane-copy.css, the same rules for the chat's drawn
# copy), pane.js (the app), chunks/ (code it loads when used) and locales/
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
REPORT_DIR="${CMUX_BUNDLE_REPORT_DIR:-}"
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
if [ -n "$REPORT_DIR" ]; then mkdir -p "$REPORT_DIR"; fi

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
# one of the sheets the page's pane.css is written from (checked below).
# --preload-list names the chunks pane.js imports statically: the page preloads them with it.
if [ -n "$REPORT_DIR" ]; then
  bun scripts/agent-pane/bundle.mjs "$SRC/acpmux/main.tsx" "$SRC/acpmux/shiki" "$WORK/pane/pane.js" --split --css-inputs "$WORK/imported-sheets" --preload-list "$WORK/preload-chunks" --metafile "$REPORT_DIR/agent-pane.json"
else
  bun scripts/agent-pane/bundle.mjs "$SRC/acpmux/main.tsx" "$SRC/acpmux/shiki" "$WORK/pane/pane.js" --split --css-inputs "$WORK/imported-sheets" --preload-list "$WORK/preload-chunks"
fi
# Code highlighting runs in a worker beside the page (conversation/highlightPool.ts): Pierre's
# worker, bundled with the same trimmed shiki. It is the entry point itself because the package
# marks the module side-effect free, so an import of it would be dropped. Both hosts serve it
# with a policy that allows no network.
if [ -n "$REPORT_DIR" ]; then
  bun scripts/agent-pane/bundle.mjs node_modules/@pierre/diffs/dist/worker/worker.js "$SRC/acpmux/shiki" "$WORK/highlight-worker.js" --metafile "$REPORT_DIR/agent-pane-highlight-worker.json"
else
  bun scripts/agent-pane/bundle.mjs node_modules/@pierre/diffs/dist/worker/worker.js "$SRC/acpmux/shiki" "$WORK/highlight-worker.js"
fi
# An attached image's decode, scale and encode run in a worker beside the page too
# (composer/imagePool.ts), so pasting large screenshots never blocks typing.
if [ -n "$REPORT_DIR" ]; then
  bun scripts/agent-pane/bundle.mjs "$SRC/acpmux/composer/imageWorker.ts" - "$WORK/image-worker.js" --metafile "$REPORT_DIR/agent-pane-image-worker.json"
else
  bun scripts/agent-pane/bundle.mjs "$SRC/acpmux/composer/imageWorker.ts" - "$WORK/image-worker.js"
fi
# The chat's drawn copy (acpmux/chatSnapshot/boot.ts): a classic script the document runs before
# pane.js; it draws the chat's last frame once the host's `__snapshot/chat.js` (async: the document
# never waits on the host) set the chat's snapshot. Small and with no imports of the pane's.
if [ -n "$REPORT_DIR" ]; then
  bun build "$SRC/acpmux/chatSnapshot/boot.ts" --format=iife --target=browser --minify --outfile "$WORK/chat-snapshot.js" --metafile="$REPORT_DIR/agent-pane-chat-snapshot.json" >/dev/null
else
  bun build "$SRC/acpmux/chatSnapshot/boot.ts" --format=iife --target=browser --minify --outfile "$WORK/chat-snapshot.js" >/dev/null
fi

# The page's sheets, derived, never a hand-kept list here (a sheet missing from one shipped its
# component unstyled in the app only, and five times this month failed every app build at the check
# below): every sheet the dev server applies, in its order. dev.tsx (the dev server's entry) imports
# the base sheets in the page's order, then main.tsx, whose components import the rest; bundle.mjs
# lists them depth-first as the modules run (cssInImportOrder). A new sheet a component imports
# ships with no change here, after the base sheets, and the app and the dev server agree.
bun scripts/agent-pane/bundle.mjs "$SRC/acpmux/dev.tsx" "$SRC/acpmux/shiki" "$WORK/order/dev.js" --split --css-inputs "$WORK/page-sheets" --css-inputs-only
# A sheet's own @import never loads here (mid-sheet in the joined pane.css): the walk
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
# FOCUS-RING: every `:focus-visible` asks whether the keyboard earned the ring, as in the Vite build
# (postcss.config.mjs, which this joined sheet never reads).
bun scripts/postcss/gate-css.mjs "$WORK/styles.css"

# Same-origin script files only (no inline script, no eval; WebAssembly compiles for Ondine's Mermaid diagrams), same-origin and inline style. No connection of its own: the
# host's native transport (AgentPaneTransport) carries acpmux. No remote loads. Frames show only loopback web
# pages (URL+AgentPanePreview.swift keeps the same hosts) and the render frame
# (a render card; AgentPaneRenderFrame.swift). The page host sends the same
# script-src (PageDescriptor.agent, test/fixtures/agent-page-csp.txt).
CSP="default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src data:; media-src 'self'; font-src data:; connect-src 'none'; frame-src cmux-agent://render http://localhost:* http://127.0.0.1:* https://localhost:* https://127.0.0.1:*"

perl -pe 's/[ \t]+$//' "$WORK/styles.css" > "$WORK/pane.css"
# The chat's drawn copy draws in a shadow root under the same rules, `html`, `body` and `:root` naming
# its stand-ins (chatSnapshot/shared.ts shadowSelector): a file too, so it is parsed once a renderer.
bun scripts/agent-pane/snapshotCss.mjs "$WORK/pane.css" "$WORK/pane-copy.css"
# Each sheet is linked by its content (`?h=`): the page host lets Chromium keep an answer so named
# (cmux_page_path.h IsContentHashedQuery), and Blink gives every page that links it the one parse.
content_hash() { shasum -a 256 "$1" | cut -c1-16; }
PANE_CSS="pane.css?h=$(content_hash "$WORK/pane.css")"
COPY_CSS="pane-copy.css?h=$(content_hash "$WORK/pane-copy.css")"

{
  printf '<!doctype html>\n<html lang="en">\n<head>\n'
  printf '<meta charset="utf-8" />\n'
  printf '<meta http-equiv="Content-Security-Policy" content="%s" />\n' "$CSP"
  printf '<meta name="viewport" content="width=device-width, initial-scale=1" />\n'
  printf '<title>cmux Agent</title>\n'
  # Fetch and parse the entry while the locale scripts and inline styles load. modulepreload
  # never evaluates it: the module below still runs after the selected language is installed.
  printf '<link rel="modulepreload" href="pane.js" />\n'
  # The chunks pane.js imports statically too: without these the page learns of them only once
  # pane.js has loaded and parsed, and fetches and parses them after it, one round behind.
  while IFS= read -r chunk; do printf '<link rel="modulepreload" href="%s" />\n' "$chunk"; done < "$WORK/preload-chunks"
  printf '%s\n' "$LOADER"
  # The styles are a file, not a <style>: every chat page of the renderer shares one parsed sheet
  # (Blink keeps a linked sheet's parsed rules in its memory cache), where each page parsed its own
  # copy of the whole <style> and kept its text (bench/chat-pages-memory.bench.ts CSS=inline). The id
  # names it for the chat's drawn copy (chatSnapshot/paint.ts), which links data-copy beside it.
  printf '<link rel="stylesheet" id="cmux-pane-styles" href="%s" data-copy="%s" />\n' "$PANE_CSS" "$COPY_CSS"
  # After the root, before the module: the host's snapshot of this page's chat (a dynamic path the
  # page host answers per page, AgentPageResources.swift; async, as a busy main thread answers it
  # late and the page must not wait), then the script that draws it.
  printf '</head>\n<body>\n<main id="root"></main>\n<script async src="__snapshot/chat.js"></script>\n<script src="chat-snapshot.js"></script>\n<script type="module" src="pane.js"></script>\n</body>\n</html>\n'
} | perl -pe 's/[ \t]+$//' > "$WORK/index.html"

# KaTeX's rules and fonts load with KaTeX, only when a reply draws math (conversation/Math.tsx,
# katexStylePlugin.mjs): never in the page's pane.css, always in a chunk.
if grep -q 'KaTeX_Main' "$WORK/pane.css"; then
  echo "error: KaTeX's stylesheet reached the page's pane.css; it loads with KaTeX (katexStylePlugin.mjs)" >&2
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
cp "$WORK/pane.css" "$OUT/pane.css"
cp "$WORK/pane-copy.css" "$OUT/pane-copy.css"
cp "$WORK/pane/pane.js" "$OUT/pane.js"
rm -rf "$OUT/chunks"
cp -R "$WORK/pane/chunks" "$OUT/chunks"
cp "$WORK/highlight-worker.js" "$OUT/highlight-worker.js"
cp "$WORK/image-worker.js" "$OUT/image-worker.js"
cp "$WORK/chat-snapshot.js" "$OUT/chat-snapshot.js"
rm -rf "$OUT/locales"
cp -R "$WORK/locales" "$OUT/locales"
echo "wrote $OUT/index.html ($(wc -c < "$OUT/index.html" | tr -d ' ') bytes) pane.js ($(wc -c < "$OUT/pane.js" | tr -d ' ') bytes) and $(ls "$OUT/chunks" | wc -l | tr -d ' ') chunks"
