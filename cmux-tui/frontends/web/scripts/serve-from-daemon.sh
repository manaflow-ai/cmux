#!/usr/bin/env bash
# Serve this web frontend from a cmux-tui daemon's own listener, so a plain
# browser opens one URL and sees that daemon's real session.
#
#   scripts/serve-from-daemon.sh [--session NAME] [--port PORT] [--bin PATH] [--no-build]
#
# It builds the app into a page bundle folder as the page `web`, starts a
# headless daemon whose loopback WebSocket listener also serves that folder
# (`CMUX_TUI_PAGES_DIR`, spec/transports.md "App listener and page files"),
# and prints http://127.0.0.1:PORT/pages/web/#token=... with the credential
# the daemon minted into its 0600 file. The page connects to the same origin.
# From another machine: ssh -L PORT:127.0.0.1:PORT HOST, then open the URL.
# Nothing here changes a default: only this script starts such a daemon.
set -euo pipefail

session=web
port=7690
bin=${CMUX_TUI_BIN:-}
build=1
while [ $# -gt 0 ]; do
  case "$1" in
    --session) session=$2; shift 2 ;;
    --port) port=$2; shift 2 ;;
    --bin) bin=$2; shift 2 ;;
    --no-build) build=0; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "serve-from-daemon: unknown argument $1" >&2; exit 2 ;;
  esac
done

here=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "$bin" ]; then
  bin=$(command -v cmux-tui || true)
fi
[ -x "$bin" ] || { echo "serve-from-daemon: no cmux-tui binary (pass --bin)" >&2; exit 2; }

pages=${CMUX_TUI_PAGES_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cmux-tui/web-pages}
if [ "$build" = 1 ]; then
  (cd "$here" && npx vp build --base ./ --outDir "$pages/web" --emptyOutDir)
fi
[ -f "$pages/web/index.html" ] || { echo "serve-from-daemon: $pages/web/index.html missing" >&2; exit 2; }

# A fresh user-only folder for the socket: the daemon writes its credential
# next to it (<socket>.websocket.json), so no stale file from an earlier run
# or another owner can be read, on any platform's runtime directory.
sockdir=$(mktemp -d "${TMPDIR:-/tmp}/cmux-web.XXXXXX")
sock=$sockdir/$session.sock
CMUX_TUI_PAGES_DIR=$pages "$bin" --session "$session" --socket "$sock" --headless --ws "127.0.0.1:$port" &
daemon=$!
trap 'kill "$daemon" 2>/dev/null; wait "$daemon" 2>/dev/null; rm -rf "$sockdir"' EXIT INT TERM

credential=$sock.websocket.json
for _ in $(seq 1 100); do
  [ -s "$credential" ] && break
  kill -0 "$daemon" 2>/dev/null || { echo "serve-from-daemon: daemon exited" >&2; exit 1; }
  sleep 0.1
done
# The daemon mints the credential only when no token is configured
# (server.ws_token or --ws-token); with one, use that token in the URL.
[ -s "$credential" ] || { echo "serve-from-daemon: no credential at $credential (is server.ws_token set?)" >&2; exit 1; }
token=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).token)' "$credential")

echo "cmux on the web: http://127.0.0.1:$port/pages/web/#token=$token"
wait "$daemon"
