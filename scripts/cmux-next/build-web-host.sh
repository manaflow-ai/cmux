#!/usr/bin/env bash
# Builds the web client's agent pane as a static site (cmuxterm-hq docs/rfd/0083-cmux-web-client.md,
# step 3, "web-host"): the app's agent pane bundle (build-agent-pane-web.sh) with the web host's entry
# (webviews/src/web-host/main.ts), whose path is its route (/m/<machine>/agent/<harness>/<session>).
#
#   scripts/cmux-next/build-web-host.sh [--out DIR]   # default webviews/dist/web-host
#
# Over the app's page it changes only what a web origin needs:
# - <base href="/">: every route is a deep path, and the page's files sit at the site's root.
# - connect-src: the page opens its own connection (the dev host's loopback acpmux daemon until the
#   gateway transport), where the app's page has none (its native transport carries acpmux).
# - no __snapshot/chat.js: that is a path only the app's page host answers.
# - 404.html, a copy of index.html: a static host serves it for every route path.
# Its first-load size is held by webviews/scripts/web-host/first-load-budget.json
# (webviews/scripts/web-host/first-load-size.mjs --check).
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT="$ROOT/webviews/dist/web-host"
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

"$ROOT/scripts/cmux-next/build-agent-pane-web.sh" --entry "$ROOT/webviews/src/web-host/main.ts" --out "$OUT"

INDEX="$OUT/index.html"
grep -q "connect-src 'none'" "$INDEX" || { echo "error: the pane's CSP has no connect-src 'none' to replace" >&2; exit 1; }
grep -q '<script async src="__snapshot/chat.js"></script>' "$INDEX" || { echo "error: the pane's page has no __snapshot/chat.js script to drop" >&2; exit 1; }
perl -0pi -e '
  s{connect-src '\''none'\''}{connect-src '\''self'\'' ws://127.0.0.1:* ws://localhost:* ws://[::1]:*};
  s{<head>\n}{<head>\n<base href="/" />\n};
  s{<title>cmux Agent</title>}{<title>cmux</title>};
  s{<script async src="__snapshot/chat.js"></script>\n}{};
' "$INDEX"
cp "$INDEX" "$OUT/404.html"
echo "web host: $OUT (index.html and 404.html serve every route)"
