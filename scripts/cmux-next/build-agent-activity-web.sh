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
bun x esbuild src/agent-activity/main.tsx --bundle --format=esm --platform=browser --target=es2022 --minify --outfile="$WORK/app.js"
cat src/agent-activity/styles.css > "$WORK/styles.css"
CSP="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src ws://127.0.0.1:* ws://localhost:*"
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8" />\n<meta http-equiv="Content-Security-Policy" content="%s" />\n<meta name="viewport" content="width=device-width, initial-scale=1" />\n<title>Agent Activity</title>\n<style>\n' "$CSP"
  cat "$WORK/styles.css"
  printf '\n</style>\n</head>\n<body>\n<main id="root"></main>\n<script type="module">\n'
  perl -0pe 's{</script}{<\\/script}ig; s{<!--}{<\\!--}g' "$WORK/app.js"
  printf '\n</script>\n</body>\n</html>\n'
} > "$WORK/index.html"
if [ "$MODE" = "--check" ]; then
  cmp -s "$WORK/index.html" "$OUT" || { echo "error: Activity web bundle is stale; run scripts/cmux-next/build-agent-activity-web.sh" >&2; exit 1; }
  echo "agent activity web bundle is current"; exit 0
fi
mkdir -p "$OUT_DIR"
cp "$WORK/index.html" "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
