#!/bin/sh
# Builds each React page (webviews/src/pages/<page>) into one self-contained index.html that
# CmuxNextPages ships under Resources/pages/<page>/ (plans/cmux-next/react-pages.md). The output
# is committed; rerun this after changing a page's sources, styles or strings.
#
#   scripts/cmux-next/build-pages-web.sh          # rebuild every page
#   scripts/cmux-next/build-pages-web.sh --check  # fail if a page (or its strings) is stale
#   scripts/cmux-next/build-pages-web.sh --out DIR  # build every page into DIR/<page>/
#
# Absorbed from the Settings lead's build-settings-web.sh (branch feat-cmux-next-settings-react).
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT_ROOT="$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
MODE=build
# --out DIR writes every page (DIR/<page>/) into DIR instead (build-web-bundles.sh --out-root, checks).
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=--check ;;
    --out)
      [ $# -ge 2 ] || { echo "error: --out needs a directory" >&2; exit 2; }
      case "$2" in /*) OUT_ROOT="$2" ;; *) OUT_ROOT="$PWD/$2" ;; esac
      shift ;;
    *) echo "usage: $0 [--check] [--out DIR]" >&2; exit 2 ;;
  esac
  shift
done
PAGES="history apps coderouter cloud keybindings icon-picker settings passwords changelog"
# Pages whose string table ships as one script per locale (locales/<locale>.js), loaded before the
# app: only English and the active locale are parsed at open (R82 first-open speed).
SPLIT_STRINGS="settings"

command -v bun >/dev/null 2>&1 || { echo "error: bun is required to build the pages" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null

if [ "$MODE" = "--check" ]; then
  bun scripts/pages/gen-strings.mjs --check
else
  bun scripts/pages/gen-strings.mjs
fi

# No CSP meta: the scheme handler sends each page's policy as a header (PageCSP, strict unless a
# first-party page widens it). A meta policy would also apply and could only narrow it.
status=0
for page in $PAGES; do
  src="$ROOT/webviews/src/pages/$page"
  mkdir -p "$WORK/$page"
  # Same bundler as the agent pane: React Compiler on first-party sources, then esbuild. The
  # pages import no shiki; the alias argument points at an unused directory.
  bun scripts/agent-pane/bundle.mjs "$src/main.tsx" "$src" "$WORK/$page/app.js"
  loader=""
  case " $SPLIT_STRINGS " in
    *" $page "*) loader="$(bun scripts/pages/split-strings.mjs "$src/generated/strings.json" "$WORK/$page/locales")" ;;
  esac
  {
    printf '<!doctype html>\n<html lang="en" data-cmux-page="%s">\n<head>\n' "$page"
    printf '<meta charset="utf-8" />\n'
    printf '<meta name="viewport" content="width=device-width, initial-scale=1" />\n'
    [ -n "$loader" ] && printf '%s\n' "$loader"
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
    if [ -d "$WORK/$page/locales" ] && ! diff -rq "$WORK/$page/locales" "$OUT_ROOT/$page/locales" >/dev/null 2>&1; then
      echo "error: $OUT_ROOT/$page/locales is stale; run scripts/cmux-next/build-pages-web.sh" >&2
      status=1
    fi
  else
    mkdir -p "$OUT_ROOT/$page"
    cp "$WORK/$page/index.html" "$out"
    if [ -d "$WORK/$page/locales" ]; then
      rm -rf "$OUT_ROOT/$page/locales"
      cp -R "$WORK/$page/locales" "$OUT_ROOT/$page/locales"
    fi
    echo "wrote $out ($(wc -c < "$out" | tr -d ' ') bytes)"
  fi
done
[ "$MODE" = "--check" ] && [ "$status" -eq 0 ] && echo "page bundles are current"
exit "$status"
