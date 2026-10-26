#!/bin/sh
# Builds the Activity web screen into the package resource.
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT_DIR="$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity"
MODE=build
# --out DIR writes index.html into DIR instead (build-web-bundles.sh --out-root, checks).
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=--check ;;
    --out)
      [ $# -ge 2 ] || { echo "error: --out needs a directory" >&2; exit 2; }
      case "$2" in /*) OUT_DIR="$2" ;; *) OUT_DIR="$PWD/$2" ;; esac
      shift ;;
    *) echo "usage: $0 [--check] [--out DIR]" >&2; exit 2 ;;
  esac
  shift
done
OUT="$OUT_DIR/index.html"
command -v bun >/dev/null 2>&1 || { echo "error: bun is required" >&2; exit 1; }
"$ROOT/scripts/check-webviews-bun-version.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null
# esbuild writes the CSS the page imports (the shared desktop layer, then styles.css) to app.css.
# React is not in app.js: the page imports the one shared React every web tree uses
# (webviews/scripts/shared/shared-react.mjs) from cmux-page://cmux.shared/, which the pages build
# writes into the same web tree (pages/_shared/); the bundler prints its URL.
REACT_URL="$(bun scripts/agent-activity/bundle.mjs "$WORK")"
case "$REACT_URL" in cmux-page://cmux.shared/react-*.js) ;; *) echo "error: no shared React URL ($REACT_URL)" >&2; exit 1 ;; esac
[ -s "$WORK/app.css" ] || { echo "error: the Activity bundle has no CSS" >&2; exit 1; }
cp "$WORK/app.css" "$WORK/styles.css"
CSP="default-src 'none'; script-src 'unsafe-inline' cmux-page://cmux.shared; style-src 'unsafe-inline'; img-src data:; connect-src ws://127.0.0.1:* ws://localhost:*"
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8" />\n<meta http-equiv="Content-Security-Policy" content="%s" />\n<meta name="viewport" content="width=device-width, initial-scale=1" />\n<title>Agent Activity</title>\n<link rel="modulepreload" href="%s" />\n<style>\n' "$CSP" "$REACT_URL"
  cat "$WORK/styles.css"
  printf '\n</style>\n</head>\n<body>\n<main id="root"></main>\n<script type="module">\n'
  perl -0pe 's{</script}{<\\/script}ig; s{<!--}{<\\!--}g' "$WORK/app.js"
  printf '\n</script>\n</body>\n</html>\n'
} > "$WORK/index.html"
if [ "$MODE" = "--check" ]; then
  echo "agent activity web bundle builds"; exit 0
fi
mkdir -p "$OUT_DIR"
cp "$WORK/index.html" "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
