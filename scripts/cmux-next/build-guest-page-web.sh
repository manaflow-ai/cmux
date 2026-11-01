#!/bin/sh
# Builds the guest page (webviews/src/agent-session/guest): the page a guest of a shared agent chat
# opens in any browser (design/chat-multiplayer.md section 3). The hosted room
# (manaflow-ai/cmux-platform) serves index.html at /g/<share_id> and every other file of the
# output under /g/ (assets/, locales/). The output is build output, not committed.
#
#   scripts/cmux-next/build-guest-page-web.sh              # into webviews/dist/guest-page
#   scripts/cmux-next/build-guest-page-web.sh --out DIR    # into DIR
#
# The page loads English plus the browser's language before its module (locales/en.js and
# locales/loader.js, same-origin files; no inline script, so the room can serve it with
# `script-src 'self'`), never the whole string table.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT="$ROOT/webviews/dist/guest-page"
BASE="${CMUX_GUEST_PAGE_BASE:-/g/}"
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

command -v bun >/dev/null 2>&1 || { echo "error: bun is required to build the guest page" >&2; exit 1; }
cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null

bun scripts/pages/gen-strings.mjs agentPane
# Vite+ on bun: the page is served from the room, not byte-compared across hosts like the app bundle.
CMUX_GUEST_PAGE_OUT_DIR="$OUT" CMUX_GUEST_PAGE_BASE="$BASE" bun --bun ./node_modules/.bin/vp build --config vite.config.guest-page.mjs

# The strings, one file per language, and the loader that picks one; their URLs under BASE.
LOADER="$(bun scripts/pages/split-strings.mjs src/agent-session/acpmux/generated/strings.json "$OUT/locales" __cmuxPaneStrings --loader-file)"
LOADER="$(printf '%s' "$LOADER" | sed "s#src=\"locales/#src=\"${BASE}locales/#g")"
sed -i.bak "s#'locales/#'${BASE}locales/#; s#\"locales/#\"${BASE}locales/#" "$OUT/locales/loader.js" && rm -f "$OUT/locales/loader.js.bak"
grep -q "${BASE}locales/" "$OUT/locales/loader.js" || { echo "error: the strings loader does not name ${BASE}locales/" >&2; exit 1; }
# Before the module script, so the strings are in when the page runs.
LOADER="$LOADER" perl -0pi -e 's#(<script type="module")#$ENV{LOADER}\n    $1#' "$OUT/index.html"
grep -q "${BASE}locales/en.js" "$OUT/index.html" || { echo "error: index.html does not load the strings" >&2; exit 1; }
echo "wrote $OUT (index.html, assets/, locales/), served under $BASE"
