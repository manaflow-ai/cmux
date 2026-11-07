#!/bin/sh
# Builds the Chief web page (webviews/src/chief-web): the signed-in, mobile-first Chief conversation. The platform
# (manaflow-ai/cmux-platform) serves index.html at /c/<handle> and every other file of the
# output under /c/assets/. The output is build output, not committed.
#
#   scripts/cmux-next/build-chief-web.sh              # into webviews/dist/chief-web
#   scripts/cmux-next/build-chief-web.sh --out DIR    # into DIR
#
# The page loads English plus the browser's language before its module (assets/locales/en.js and
# assets/locales/loader.js, same-origin files; no inline script, so the room can serve it with
# `script-src 'self'`), never the whole string table.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT="$ROOT/webviews/dist/chief-web"
BASE="${CMUX_CHIEF_WEB_BASE:-/c/}"
while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      [ $# -ge 2 ] || { echo "error: --out needs a directory" >&2; exit 2; }
      case "$2" in /*) OUT="$2" ;; *) OUT="$PWD/$2" ;; esac
      shift ;;
    *) echo "usage: $0 [--out DIR]" >&2; exit 2 ;;
  esac
  shift
done

command -v bun >/dev/null 2>&1 || { echo "error: bun is required to build the Chief web page" >&2; exit 1; }
cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null

bun scripts/pages/gen-strings.mjs agentPane
# Vite+ on bun: the page is served from the room, not byte-compared across hosts like the app bundle.
CMUX_CHIEF_WEB_OUT_DIR="$OUT" CMUX_CHIEF_WEB_BASE="$BASE" bun --bun ./node_modules/.bin/vp build --config vite.config.chief-web.mjs

# The strings, one file per language, and the loader that picks one; their URLs under BASE.
LOADER="$(bun scripts/pages/split-strings.mjs src/agent-session/acpmux/generated/strings.json "$OUT/assets/locales" __cmuxPaneStrings --loader-file)"
LOADER="$(printf '%s' "$LOADER" | sed "s#src=\"locales/#src=\"${BASE}assets/locales/#g")"
sed -i.bak "s#'locales/#'${BASE}assets/locales/#; s#\"locales/#\"${BASE}assets/locales/#" "$OUT/assets/locales/loader.js" && rm -f "$OUT/assets/locales/loader.js.bak"
grep -q "${BASE}assets/locales/" "$OUT/assets/locales/loader.js" || { echo "error: the strings loader does not name ${BASE}assets/locales/" >&2; exit 1; }
# Before the module script, so the strings are in when the page runs.
LOADER="$LOADER" perl -0pi -e 's#(<script type="module")#$ENV{LOADER}\n    $1#' "$OUT/index.html"
grep -q "${BASE}assets/locales/en.js" "$OUT/index.html" || { echo "error: index.html does not load the strings" >&2; exit 1; }
echo "wrote $OUT (index.html, assets/), served under $BASE"
