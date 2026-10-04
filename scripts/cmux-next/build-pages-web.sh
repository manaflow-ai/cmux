#!/bin/sh
# Builds each React page (webviews/src/pages/<page>) into one self-contained index.html that
# CmuxNextPages ships under Resources/pages/<page>/ (plans/cmux-next/react-pages.md). The output
# is committed; rerun this after changing a page's sources, styles or strings.
#
#   scripts/cmux-next/build-pages-web.sh          # rebuild every page
#   scripts/cmux-next/build-pages-web.sh --check  # fail if a page (or its strings) is stale
#
# Absorbed from the Settings lead's build-settings-web.sh (branch feat-cmux-next-settings-react).
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT_ROOT="$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
MODE="${1:-build}"
PAGES="history"

command -v bun >/dev/null 2>&1 || { echo "error: bun is required to build the pages" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null

if [ "$MODE" = "--check" ]; then
  node scripts/pages/gen-strings.mjs --check
else
  node scripts/pages/gen-strings.mjs
fi

# Inline script and style only, and no network: the page talks to the app through the cmuxPage
# message handler. The scheme handler sends the same policy as a header.
CSP="default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:"
status=0
for page in $PAGES; do
  src="$ROOT/webviews/src/pages/$page"
  mkdir -p "$WORK/$page"
  # Same bundler as the agent pane: React Compiler on first-party sources, then esbuild. The
  # pages import no shiki; the alias argument points at an unused directory.
  bun scripts/agent-pane/bundle.mjs "$src/main.tsx" "$src" "$WORK/$page/app.js"
  {
    printf '<!doctype html>\n<html lang="en" data-cmux-page="%s">\n<head>\n' "$page"
    printf '<meta charset="utf-8" />\n'
    printf '<meta http-equiv="Content-Security-Policy" content="%s" />\n' "$CSP"
    printf '<meta name="viewport" content="width=device-width, initial-scale=1" />\n'
    printf '<style>\n'
    [ -f "$WORK/$page/app.css" ] && cat "$WORK/$page/app.css"
    printf '\n</style>\n</head>\n<body>\n<main id="root"></main>\n<script type="module">\n'
    perl -0pe 's{</script}{<\\/script}ig; s{<!--}{<\\!--}g' "$WORK/$page/app.js"
    printf '\n</script>\n</body>\n</html>\n'
  } | perl -pe 's/[ \t]+$//' > "$WORK/$page/index.html"

  out="$OUT_ROOT/$page/index.html"
  if [ "$MODE" = "--check" ]; then
    if ! cmp -s "$WORK/$page/index.html" "$out"; then
      echo "error: $out is stale; run scripts/cmux-next/build-pages-web.sh" >&2
      status=1
    fi
  else
    mkdir -p "$OUT_ROOT/$page"
    cp "$WORK/$page/index.html" "$out"
    echo "wrote $out ($(wc -c < "$out" | tr -d ' ') bytes)"
  fi
done
[ "$MODE" = "--check" ] && [ "$status" -eq 0 ] && echo "page bundles are current"
exit "$status"
