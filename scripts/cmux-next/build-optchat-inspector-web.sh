#!/bin/sh
# Builds the Chief memory inspector (webviews/src/optchat-inspector) into one
# self-contained page that optchat-chief compiles in (inspect/http.rs serves it).
# Usage: build-optchat-inspector-web.sh [--check | --out DIR]
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT="$ROOT/Native/OptChat/optchat-chief/inspector/index.html"
MODE=build
if [ "$#" -gt 0 ]; then
  case "$1" in
    --check) MODE=check ;;
    --out)
      [ "$#" -ge 2 ] || { echo "error: --out needs a directory" >&2; exit 2; }
      case "$2" in /*) OUT="$2/index.html" ;; *) OUT="$PWD/$2/index.html" ;; esac
      ;;
    *) echo "usage: $0 [--check | --out DIR]" >&2; exit 2 ;;
  esac
fi
command -v bun >/dev/null 2>&1 || { echo "error: bun is required" >&2; exit 1; }
"$ROOT/scripts/check-webviews-bun-version.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null
bun x esbuild src/optchat-inspector/main.tsx --bundle --format=esm --platform=browser --target=es2022 --minify \
  --define:process.env.NODE_ENV='"production"' --outfile="$WORK/app.js" --log-level=warning
CSP="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'"
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8" />\n<meta http-equiv="Content-Security-Policy" content="%s" />\n<meta name="viewport" content="width=device-width, initial-scale=1" />\n<title>Chief Memory Inspector</title>\n<style>\n' "$CSP"
  cat src/optchat-inspector/styles.css
  printf '\n</style>\n</head>\n<body>\n<div id="root"></div>\n<script type="module">\n'
  perl -0pe 's{</script}{<\\/script}ig; s{<!--}{<\\!--}g' "$WORK/app.js"
  printf '\n</script>\n</body>\n</html>\n'
} > "$WORK/index.html"
if [ "$MODE" = check ]; then
  cmp -s "$WORK/index.html" "$OUT" || { echo "error: the memory inspector page is stale; run scripts/cmux-next/build-optchat-inspector-web.sh" >&2; exit 1; }
  echo "memory inspector page is current"; exit 0
fi
mkdir -p "$(dirname "$OUT")"
cp "$WORK/index.html" "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
