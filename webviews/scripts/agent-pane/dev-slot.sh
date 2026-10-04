#!/usr/bin/env bash
# Run the agent pane in a plain browser against a standalone acpmux daemon, with Vite hot reload.
# Each slot is one isolated pair: a daemon with its own ACPMUX_HOME, port and fresh token, and a
# Vite dev server on its own port that the daemon trusts as its only extra origin. Run several
# slots (one per worktree) to iterate on variants side by side.
#
#   webviews/scripts/agent-pane/dev-slot.sh up 1 [--cwd DIR]   # start slot 1, print its URL
#   webviews/scripts/agent-pane/dev-slot.sh url 1              # print the URL again
#   webviews/scripts/agent-pane/dev-slot.sh down 1             # stop slot 1 (sessions are kept)
#   webviews/scripts/agent-pane/dev-slot.sh status
#
# Slot N uses daemon port 47900+N, Vite port 4180+N and /tmp/acpdev-N (sessions survive restarts;
# `rm -rf` it for a clean daemon). The daemon binary is $ACPMUX_BIN, else the newest acpmux bundled
# in a tagged DerivedData build, else `acpmux` on PATH. It must be new enough for this pane.
set -euo pipefail

WEBVIEWS="$(cd "$(dirname "$0")/../.." && pwd)"
REPO="$(cd "$WEBVIEWS/.." && pwd)"

usage() { sed -n 2,15p "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

cmd="${1:-}"; [[ -n "$cmd" ]] || usage 1; shift
if [[ "$cmd" == status ]]; then
  for dir in /tmp/acpdev-*; do
    [[ -d "$dir" ]] || continue
    slot="${dir##*-}"
    state=down
    if [[ -f "$dir/daemon.pid" ]] && kill -0 "$(cat "$dir/daemon.pid")" 2>/dev/null; then state=up; fi
    echo "slot $slot: daemon $state, vite $( [[ -f "$dir/vite.pid" ]] && kill -0 "$(cat "$dir/vite.pid")" 2>/dev/null && echo up || echo down) ($(cat "$dir/worktree" 2>/dev/null || echo ?))"
  done
  exit 0
fi

slot="${1:-}"; shift || true
[[ "$slot" =~ ^[0-9]{1,2}$ ]] || { echo "slot must be 0-99" >&2; usage 1; }
cwd="$REPO"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) cwd="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

home="/tmp/acpdev-$slot"
daemon_port=$((47900 + slot))
vite_port=$((4180 + slot))
vite_origin="http://127.0.0.1:$vite_port"

stop_pid() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local pid; pid="$(cat "$file")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$file"
}

# Vite runs under bun and node children; whatever still listens on the slot's ports is the slot's.
stop_port() {
  local pids; pids="$(lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
}

print_url() {
  local token; token="$(cat "$home/token")"
  local fragment="endpoint=ws://127.0.0.1:$daemon_port/&token=$token&cwd=$(cat "$home/cwd")"
  echo "$vite_origin/#$fragment"
}

wait_port() {
  local port="$1" log="$2"
  for _ in $(seq 150); do
    nc -z 127.0.0.1 "$port" 2>/dev/null && return 0
    sleep 0.2
  done
  echo "port $port did not open; see $log" >&2
  tail -20 "$log" >&2
  return 1
}

resolve_bin() {
  if [[ -n "${ACPMUX_BIN:-}" ]]; then echo "$ACPMUX_BIN"; return; fi
  local newest
  newest="$(ls -t "$HOME"/Library/Developer/Xcode/DerivedData/cmux-*/Build/Products/Debug/*.app/Contents/Resources/bin/acpmux 2>/dev/null | head -1 || true)"
  if [[ -n "$newest" ]]; then echo "$newest"; return; fi
  command -v acpmux || { echo "no acpmux binary: set ACPMUX_BIN" >&2; exit 1; }
}

case "$cmd" in
  up)
    stop_pid "$home/vite.pid"; stop_port "$vite_port"
    stop_pid "$home/daemon.pid"; stop_port "$daemon_port"
    mkdir -p "$home"
    bin="$(resolve_bin)"
    # A fresh token every start; the daemon trusts only this slot's Vite origin.
    openssl rand -hex 24 > "$home/token"
    chmod 600 "$home/token"
    echo "$cwd" > "$home/cwd"
    echo "$WEBVIEWS" > "$home/worktree"
    token="$(cat "$home/token")"
    python3 - "$home/config.json" "$daemon_port" "$token" "$vite_origin" <<'PY'
import json, os, sys
path, port, token, origin = sys.argv[1:]
config = json.load(open(path)) if os.path.exists(path) else {}
config["websocket"] = {"listen": f"127.0.0.1:{port}", "token": token, "allowed_origins": [origin]}
with open(path, "w") as f:
    json.dump(config, f, indent=2)
os.chmod(path, 0o600)
PY
    echo "acpmux: $("$bin" --version) ($bin)"
    # Current daemons trust a dev origin only through --allow-dev-origin (never saved); older ones
    # read websocket.allowed_origins above.
    origin_args=()
    if "$bin" daemon run --help 2>/dev/null | grep -q -- --allow-dev-origin; then
      origin_args=(--allow-dev-origin "$vite_origin")
    fi
    (cd "$cwd" && ACPMUX_HOME="$home" nohup "$bin" daemon run --listen "127.0.0.1:$daemon_port" --token "$token" \
      "${origin_args[@]}" >"$home/daemon.log" 2>&1 & echo $! >"$home/daemon.pid")
    wait_port "$daemon_port" "$home/daemon.log"
    [[ -d "$WEBVIEWS/node_modules" ]] || (cd "$WEBVIEWS" && bun install --frozen-lockfile >/dev/null)
    (cd "$WEBVIEWS" && CMUX_AGENT_PANE_DEV_PORT="$vite_port" nohup bun run dev:agent-pane \
      >"$home/vite.log" 2>&1 & echo $! >"$home/vite.pid")
    wait_port "$vite_port" "$home/vite.log"
    echo "logs: $home/daemon.log $home/vite.log"
    print_url
    ;;
  url) print_url ;;
  down)
    stop_pid "$home/vite.pid"; stop_port "$vite_port"
    stop_pid "$home/daemon.pid"; stop_port "$daemon_port"
    echo "slot $slot stopped"
    ;;
  *) usage 1 ;;
esac
