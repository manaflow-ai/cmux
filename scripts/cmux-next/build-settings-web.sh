#!/bin/sh
# Builds the React Settings page (webviews/src/settings) into one self-contained index.html
# that CmuxNextSettingsWindow ships as a resource. The output is committed; rerun this after
# changing the TypeScript sources, the styles, the schema or the string catalogs.
#
#   scripts/cmux-next/build-settings-web.sh          # rebuild the resource
#   scripts/cmux-next/build-settings-web.sh --check  # fail if it (or the strings) is stale
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SRC="$ROOT/webviews/src/settings"
OUT="$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextSettingsWindow/Resources/settings-page"
MODE="${1:-build}"

command -v bun >/dev/null 2>&1 || { echo "error: bun is required to build the settings page" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null

if [ "$MODE" = "--check" ]; then
  node scripts/pages/gen-strings.mjs --check settings
else
  node scripts/pages/gen-strings.mjs settings
fi

# Same bundler as the agent pane: React Compiler on first-party sources, then esbuild.
bun scripts/agent-pane/bundle.mjs "$SRC/main.tsx" - "$WORK/app.js"

# Inline script and style only. No network at all: the page talks to the app through
# the cmuxSettings script message handler.
CSP="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'"

{
  printf '<!doctype html>\n<html lang="en">\n<head>\n'
  printf '<meta charset="utf-8" />\n'
  printf '<meta http-equiv="Content-Security-Policy" content="%s" />\n' "$CSP"
  printf '<meta name="viewport" content="width=device-width, initial-scale=1" />\n'
  printf '<title>Settings</title>\n<style>\n'
  cat "$SRC/styles.css"
  printf '\n</style>\n</head>\n<body>\n<div id="root"></div>\n<script type="module">\n'
  perl -0pe 's{</script}{<\\/script}ig; s{<!--}{<\\!--}g' "$WORK/app.js"
  printf '\n</script>\n</body>\n</html>\n'
} | perl -pe 's/[ \t]+$//' > "$WORK/index.html"

if [ "$MODE" = "--check" ]; then
  if ! cmp -s "$WORK/index.html" "$OUT/index.html"; then
    echo "error: $OUT/index.html is stale; run scripts/cmux-next/build-settings-web.sh" >&2
    exit 1
  fi
  echo "settings page web bundle is current"
  exit 0
fi

mkdir -p "$OUT"
cp "$WORK/index.html" "$OUT/index.html"
echo "wrote $OUT/index.html ($(wc -c < "$OUT/index.html" | tr -d ' ') bytes)"
