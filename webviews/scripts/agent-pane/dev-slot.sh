#!/usr/bin/env bash
# Run the webviews in a plain browser with Vite hot reload: one dev server per slot serves every
# surface as a path (webviews/dev-server/plugins.ts), next to a standalone acpmux daemon for the
# agent pane. The daemon has its own ACPMUX_HOME, port and fresh token, and trusts the slot's Vite
# origin as its only extra origin. Run several slots (one per worktree) to compare side by side.
#
#   webviews/scripts/agent-pane/dev-slot.sh up 1 [--cwd DIR]   # start slot 1, print its URLs
#   webviews/scripts/agent-pane/dev-slot.sh url 1              # print the URLs again
#   webviews/scripts/agent-pane/dev-slot.sh down 1             # stop slot 1 (sessions are kept)
#   webviews/scripts/agent-pane/dev-slot.sh status
#
# Slot N uses daemon port 47900+N, Vite port 4180+N and /tmp/acpdev-N (logs; sessions survive
# restarts, `rm -rf` it for a clean daemon). Binaries come from the newest built app
# (/tmp/panedev-*-app/*.app or a tagged DerivedData build): acpmux is $ACPMUX_BIN, else that, else
# `acpmux` on PATH, and must be new enough for this pane; cmux-diff-sidecar is
# $CMUX_DIFF_SIDECAR_BIN, else that (only /diff/ needs it).
set -euo pipefail

WEBVIEWS="$(cd "$(dirname "$0")/../.." && pwd)"
REPO="$(cd "$WEBVIEWS/.." && pwd)"

usage() { sed -n 2,17p "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

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
  echo "agent pane: $vite_origin/agent-pane/#$fragment"
  echo "diff:       $vite_origin/diff/"
  echo "markdown:   $vite_origin/markdown (classic viewer: /markdown/viewer)"
  echo "index:      $vite_origin/"
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

# The newest $1 bundled in a built app, or nothing.
newest_app_bin() {
  ls -t /tmp/panedev-*-app/*.app/Contents/Resources/bin/"$1" \
    "$HOME"/Library/Developer/Xcode/DerivedData/cmux-*/Build/Products/Debug/*.app/Contents/Resources/bin/"$1" \
    2>/dev/null | head -1 || true
}

resolve_bin() {
  if [[ -n "${ACPMUX_BIN:-}" ]]; then echo "$ACPMUX_BIN"; return; fi
  local newest; newest="$(newest_app_bin acpmux)"
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
      ${origin_args[@]+"${origin_args[@]}"} </dev/null >"$home/daemon.log" 2>&1 & echo $! >"$home/daemon.pid")
    wait_port "$daemon_port" "$home/daemon.log"
    sidecar="${CMUX_DIFF_SIDECAR_BIN:-$(newest_app_bin cmux-diff-sidecar)}"
    if [[ -n "$sidecar" ]]; then echo "cmux-diff-sidecar: $sidecar"; else echo "no cmux-diff-sidecar: /diff/ fails until CMUX_DIFF_SIDECAR_BIN is set" >&2; fi
    [[ -d "$WEBVIEWS/node_modules" ]] || (cd "$WEBVIEWS" && bun install --frozen-lockfile >/dev/null)
    # Detached with no inherited stdio, so the caller's shell returns.
    # The slot's folder also keeps the viewer empty states' recents (viewer-recents.json).
    (cd "$WEBVIEWS" && CMUX_WEBVIEWS_DEV_PORT="$vite_port" CMUX_DIFF_SIDECAR="$sidecar" \
      CMUX_WEBVIEWS_DEV_STATE_DIR="$home" nohup bun run dev \
      </dev/null >"$home/vite.log" 2>&1 & echo $! >"$home/vite.pid")
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
