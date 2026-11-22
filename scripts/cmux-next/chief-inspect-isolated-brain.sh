#!/usr/bin/env bash
# Live check of the remote inspector path on an isolated test brain (never the
# real brain): the app bundle's cmux-tui daemon with CMUX_TUI_CHIEF_TOOLS_SOCKET,
# the bundle's optchat-chief host on a seeded scratch memory, then chief-inspect
# over the daemon socket (a trusted local client, as the owner_session splice is).
# Only processes this script starts are stopped (by pid).
#
# usage: chief-inspect-isolated-brain.sh APP OUT_DIR
set -euo pipefail
APP="$1" OUT="$2"
BIN="$APP/Contents/Resources/bin"
# Short: the tools and daemon sockets must fit sun_path.
BRAIN="$(mktemp -d /tmp/cib.XXXXXX)"
SOCK="$BRAIN/daemon/cmux.sock"
TOOLS="$BRAIN/mux/optchat/tools.sock"
mkdir -p "$BRAIN/daemon" "$BRAIN/mux" "$OUT"
pids=()
# Stops what this script started, and the children that run for this brain only
# (its acpmux): matched by the brain's unique directory, never a broad pattern.
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  for p in $(pgrep -f "$BRAIN" || true); do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

python3 - "$BRAIN/notes.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for k in range(64):
        f.write(json.dumps({"text": f"isolated brain note {k}: the inspector reads this through chief-inspect.", "kind": "note"}) + "\n")
PY
"$BIN/optchat-chief" import --mux-home "$BRAIN/mux" "$BRAIN/notes.jsonl"

env -i HOME="$HOME" PATH=/usr/bin:/bin CMUX_TUI_STATE_DIR="$BRAIN/daemon/state" CMUX_TUI_CHIEF_TOOLS_SOCKET="$TOOLS" \
  "$BIN/cmux-tui" --headless --socket "$SOCK" >"$OUT/daemon.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 100); do [[ -S "$SOCK" ]] && break; sleep 0.1; done
# One JSON-lines request on the daemon socket (a trusted local Unix client).
ask() {
  python3 - "$SOCK" "$1" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sys.argv[1])
req = json.loads(sys.argv[2]); req["id"] = 1
s.sendall((json.dumps(req) + "\n").encode())
buf = b""
while not buf.endswith(b"\n"):
    chunk = s.recv(1 << 20)
    if not chunk: break
    buf += chunk
print(buf.decode().strip())
PY
}
# The host acts as agent_mux with a token the local user mints (as the app does).
ask '{"cmd":"conversation-agent-token","participant":"agent_mux"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["token"])' > "$BRAIN/agent-token"
chmod 600 "$BRAIN/agent-token"
# The host starts the brain's own acpmux under ACPMUX_HOME (never the user's).
mkdir -p "$BRAIN/acpmux"
env -i HOME="$HOME" PATH=/usr/bin:/bin:"$BIN" MUX_HOME="$BRAIN/mux" MUX_AGENT_TOKEN_FILE="$BRAIN/agent-token" OPTCHAT_INSPECTOR=1 \
  ACPMUX_HOME="$BRAIN/acpmux" ACPMUX_BIN="$BIN/acpmux" MUX_HARNESS=claude-sr CMUX_DAEMON_SOCKET="$SOCK" \
  "$BIN/optchat-chief" host --daemon-socket "$SOCK" --mux-home "$BRAIN/mux" >"$OUT/host.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 300); do [[ -S "$TOOLS" ]] && break; sleep 0.1; done
[[ -S "$TOOLS" ]] || { echo "the host served no tools socket"; tail -20 "$OUT/host.log"; exit 1; }

echo "== identify capability"
ask '{"cmd":"identify"}' | python3 -c 'import json,sys; print("chief-inspect-v1" in json.dumps(json.load(sys.stdin)))'
for req in '{"cmd":"chief-inspect","path":"/api/status"}' \
           '{"cmd":"chief-inspect","path":"/api/node","query":{"name":"0+8"}}' \
           '{"cmd":"chief-inspect","path":"/api/turn","query":{"key":"now"}}' \
           '{"cmd":"chief-inspect","path":"/api/ticket"}'; do
  echo "== $req"
  ask "$req" 2>&1 | head -c 600; echo
done
