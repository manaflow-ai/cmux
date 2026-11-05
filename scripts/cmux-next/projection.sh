#!/usr/bin/env bash
# A projection window of the running app for a worktree (manaflow-ai/cmuxterm-hq#7149 L10): a real
# window of your NIGHTLY or DEV, with your settings, theme, backdrop and keys and the live daemon's
# terminals, whose pages and agent panes load from that worktree's webviews dev server. Saving a web
# file there hot-reloads that window (Vite HMR, React Fast Refresh keeps component state); your other
# windows keep their pages, and web-dev.json is not touched.
#
#   projection.sh open [WORKTREE] [--port N] [--test CMD]
#                        # start WORKTREE's dev server (default: this checkout) and open the window;
#                        # --test names the one test Debug > Run Projection Test runs there
#   projection.sh test [CMD]          # run the projection's test (or CMD) in its window
#   projection.sh stop [WORKTREE]     # stop the dev server this script started for WORKTREE
#   projection.sh status [WORKTREE]
#
# The app side is `debug.projection` and `debug.projection.runTest` (WebProjection.swift); this
# script runs them with `cmux action run` ($CMUX_CLI, else `cmux`). Settings, theme and keybinding
# edits in cmux-next.json apply to every window live, the projection included, with no restart.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cli="${CMUX_CLI:-cmux}"
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }

# The worktree's state folder (pid file, log), keyed by its absolute path.
state_for() {
  local key
  key="$(printf '%s' "$1" | shasum -a 256 | cut -c1-12)"
  echo "${CMUX_PROJECTION_STATE_DIR:-$HOME/Library/Caches/cmux-next/projection}/$key"
}

# A port per worktree, 4290-4389, so two projections never share one.
port_for() { echo $((4290 + $(printf '%s' "$1" | cksum | cut -d' ' -f1) % 100)); }

answers() {
  curl -fsS -o /dev/null --max-time 3 --retry "${2:-0}" --retry-delay 1 --retry-connrefused --retry-all-errors \
    "http://127.0.0.1:$1/agent-pane/index.html" 2>/dev/null
}

# The dev server's pid while it still runs bun, else empty.
live_pid() {
  local file="$1/dev-server.pid" pid
  [[ -f "$file" ]] || return 0
  pid="$(cat "$file")"
  [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$(basename "$(ps -o comm= -p "$pid" 2>/dev/null)")" == bun ]] && echo "$pid"
  return 0
}

start_server() {
  local tree="$1" port="$2" state="$3"
  [[ -f "$tree/webviews/package.json" ]] || { echo "no webviews/ in $tree" >&2; exit 1; }
  if [[ -n "$(live_pid "$state")" ]] && answers "$port"; then
    echo "dev server: http://127.0.0.1:$port/ from $tree (already running)"
    return
  fi
  answers "$port" && { echo "127.0.0.1:$port answers, but not from a server this script started; use --port N" >&2; exit 1; }
  mkdir -p "$state"
  [[ -d "$tree/webviews/node_modules" ]] || (cd "$tree/webviews" && bun install --frozen-lockfile >/dev/null)
  (cd "$tree/webviews" && bun scripts/pages/gen-strings.mjs --best-effort >/dev/null 2>&1)
  # Its own process group (set -m), so `stop` ends bun and its children together.
  ( set -m
    ( cd "$tree/webviews" && CMUX_WEBVIEWS_DEV_PORT="$port" exec nohup bun run dev ) </dev/null >"$state/dev-server.log" 2>&1 &
    echo $! >"$state/dev-server.pid" )
  echo "$tree" >"$state/tree"
  echo "$port" >"$state/port"
  answers "$port" 60 || { echo "the dev server did not start; see $state/dev-server.log" >&2; exit 1; }
  echo "dev server: http://127.0.0.1:$port/ from $tree (log: $state/dev-server.log)"
}

cmd="${1:-}"; [[ -n "$cmd" ]] || usage 1; shift
case "$cmd" in
  open)
    tree="$ROOT" port="" test=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --port) port="${2:?--port needs a value}"; shift 2 ;;
        --test) test="${2:?--test needs a value}"; shift 2 ;;
        -h|--help) usage ;;
        -*) usage 1 ;;
        *) tree="$(cd "$1" && pwd)"; shift ;;
      esac
    done
    state="$(state_for "$tree")"
    port="${port:-$(port_for "$tree")}"
    start_server "$tree" "$port" "$state"
    args=(action run debug.projection --server "http://127.0.0.1:$port/" --worktree "$tree")
    [[ -n "$test" ]] && args+=(--test "$test")
    "$cli" "${args[@]}"
    ;;
  test)
    if [[ $# -gt 0 ]]; then "$cli" action run debug.projection.runTest --test "$1"; else "$cli" action run debug.projection.runTest; fi
    ;;
  stop)
    tree="$(cd "${1:-$ROOT}" && pwd)"; state="$(state_for "$tree")"
    pid="$(live_pid "$state")"
    [[ -n "$pid" ]] && kill -- "-$pid" 2>/dev/null || true
    rm -f "$state/dev-server.pid"
    echo "stopped the projection server for $tree"
    ;;
  status)
    tree="$(cd "${1:-$ROOT}" && pwd)"; state="$(state_for "$tree")"
    if [[ -n "$(live_pid "$state")" ]]; then
      echo "dev server: http://127.0.0.1:$(cat "$state/port")/ from $tree"
    else
      echo "no projection server for $tree"
    fi
    ;;
  -h|--help) usage ;;
  *) usage 1 ;;
esac
