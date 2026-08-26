#!/usr/bin/env bash
# Local transport spike: the cmux-tui remote daemon and a client on one
# machine, no sandbox. Same protocol path as scripts/spike-cmux-tui-blaxel.sh
# (Noise over /v1/link, enrollment, snapshot resync); a local process stands
# in for the cloud VM so anyone can run the loop without Blaxel credentials.
# See docs/cloud-cmux-tui-daemon.md.
#
#   scripts/spike-cmux-tui-local.sh up       --name <n> [--binary <cmux-tui>]
#   scripts/spike-cmux-tui-local.sh evidence --name <n>
#   scripts/spike-cmux-tui-local.sh attach   --name <n>   # interactive remote TUI
#   scripts/spike-cmux-tui-local.sh down     --name <n>
#
# `up` starts a headless `server start --remote-ws` daemon on a free loopback
# port with isolated state under ~/.cache/cmux-tui-local-spike/<n>/, enrolls
# this machine as a client device, and approves the enrollment daemon-side.
# `evidence` is the self-checking reconnect proof: spawn a PTY bash over
# workspace RPC, write a marker, snapshot, SIGKILL the client link, connect
# fresh, and assert the new connection's snapshot still carries the pre-kill
# marker with an advanced through_sequence (structured restore, not raw
# replay). Default binary: cmux-tui/target/debug/cmux-tui next to this repo
# (`cargo build -p cmux-tui` in cmux-tui/).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cmd="${1:-}"; shift || true
NAME="" BINARY=""
while (( $# )); do
  case "$1" in
    --name) shift; NAME="${1:?--name needs a value}" ;;
    --binary) shift; BINARY="${1:?--binary needs a value}" ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done
[[ -n "$NAME" ]] || { echo "--name is required" >&2; exit 64; }
case "$cmd" in up|evidence|attach|down) ;; *) sed -n '7,12p' "$0"; exit 64 ;; esac

BIN="${BINARY:-${CMUX_TUI_BIN:-$REPO_ROOT/cmux-tui/target/debug/cmux-tui}}"
[[ -x "$BIN" ]] || { echo "cmux-tui binary not found at $BIN (cargo build -p cmux-tui)" >&2; exit 66; }

SESSION="spike-$NAME"
ROOT="$HOME/.cache/cmux-tui-local-spike/$NAME"
CLIENT_STATE="$ROOT/client-state"
VM_STATE="$ROOT/vm"

route() { printf 'ws://127.0.0.1:%s/v1/link' "$(cat "$ROOT/port")"; }
vm_enroll() { # action [args...] -> runs against the daemon's admin socket
  local action="$1"; shift
  "$BIN" remote enroll "$action" "$@" --session "$SESSION" --state-dir "$VM_STATE/remote-state" --json
}
rpc() { CMUX_REMOTE_STATE_DIR="$CLIENT_STATE" "$BIN" remote rpc "$(route)"; }

case "$cmd" in
up)
  mkdir -p "$ROOT" "$VM_STATE" "$ROOT/work"
  chmod 700 "$ROOT"

  PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  echo "$PORT" > "$ROOT/port"

  echo "==> start remote daemon (session $SESSION, ws 127.0.0.1:$PORT)"
  "$BIN" server start --session "$SESSION" --headless \
    --state "$VM_STATE/session-state" --socket "$VM_STATE/mux.sock" \
    --remote-ws "127.0.0.1:$PORT" --remote-state-dir "$VM_STATE/remote-state" \
    > "$ROOT/daemon.log" 2>&1 &
  echo $! > "$ROOT/daemon.pid"
  for _ in $(seq 1 50); do
    python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(0.2); s.connect(("127.0.0.1",int(sys.argv[1]))); s.close()' "$PORT" 2>/dev/null && break
    kill -0 "$(cat "$ROOT/daemon.pid")" 2>/dev/null || { echo "daemon exited; see $ROOT/daemon.log" >&2; exit 1; }
    sleep 0.2
  done

  echo "==> enroll this machine"
  vm_enroll create --ttl 300 \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["uri"])' > "$ROOT/invitation"
  chmod 600 "$ROOT/invitation"
  CMUX_REMOTE_STATE_DIR="$CLIENT_STATE" "$BIN" remote connect "$(route)" \
    --invite-file "$ROOT/invitation" --device-name "spike-local-$NAME" --headless \
    > "$ROOT/connect.log" 2>&1 &
  echo $! > "$ROOT/connect.pid"
  for _ in $(seq 1 30); do
    invitation_id="$(vm_enroll pending | python3 -c 'import json,sys; p=json.load(sys.stdin); print(p[0]["invitation_id"] if p else "")')"
    if [[ -n "$invitation_id" ]]; then
      vm_enroll approve "$invitation_id" > /dev/null
      echo "    approved enrollment $invitation_id"
      break
    fi
    sleep 1
  done
  [[ -n "${invitation_id:-}" ]] || { echo "enrollment was never requested; see $ROOT/connect.log" >&2; exit 1; }

  echo "==> up. next: $0 evidence --name $NAME"
  ;;

evidence)
  echo "==> spawn PTY bash in a remote workspace, write marker, snapshot"
  ws="$(printf '%s\n' "{\"type\":\"open-workspace\",\"root\":\"$ROOT/work\"}" | rpc \
    | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["id"])')"
  proc="$(python3 -c 'import json,sys; print(json.dumps({"type":"spawn-process","workspace":sys.argv[1],"argv":["bash"],"cwd":None,"env":{},"io":{"type":"pty","cols":100,"rows":30,"term":"xterm-256color","eof":"control-d"},"lifetime":"detached"}))' "$ws" \
    | rpc | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["process"])')"
  echo "    workspace $ws process $proc"
  data="$(printf 'echo SPIKE-BEFORE-KILL\n' | base64)"
  { printf '%s\n' "{\"type\":\"write-process\",\"process\":\"$proc\",\"write_id\":1,\"data\":\"$data\",\"eof\":false}"; sleep 1; \
    printf '%s\n' "{\"type\":\"snapshot-process-terminal\",\"process\":\"$proc\"}"; } | rpc > "$ROOT/snapshot-before.json"

  echo "==> SIGKILL the client link, reconnect fresh, write again, snapshot"
  kill -9 "$(cat "$ROOT/connect.pid")" 2>/dev/null || true
  data2="$(printf 'echo SPIKE-AFTER-RECONNECT\n' | base64)"
  { printf '%s\n' "{\"type\":\"write-process\",\"process\":\"$proc\",\"write_id\":2,\"data\":\"$data2\",\"eof\":false}"; sleep 1; \
    printf '%s\n' "{\"type\":\"snapshot-process-terminal\",\"process\":\"$proc\"}"; } | rpc > "$ROOT/snapshot-after.json"

  python3 - "$ROOT/snapshot-before.json" "$ROOT/snapshot-after.json" <<'PY'
import json, sys

def snapshot(path):
    for line in open(path):
        d = json.loads(line)
        if d["type"] == "process-terminal-snapshot":
            return d["snapshot"]
    sys.exit(f"no snapshot frame in {path}")

def text(s):
    return "\n".join(
        "".join(run.get("text", "") for run in (row.get("runs") or []))
        for row in s["rows"]
    )

before, after = snapshot(sys.argv[1]), snapshot(sys.argv[2])
restored = text(after)
for line in restored.splitlines():
    if line.strip():
        print(f"    {line.rstrip()}")
assert "SPIKE-BEFORE-KILL" in restored, "pre-kill marker missing after reconnect"
assert "SPIKE-AFTER-RECONNECT" in restored, "post-reconnect write missing"
assert after["through_sequence"] > before["through_sequence"], "through_sequence did not advance"
print(f"PASS: snapshot restored across kill (through_sequence "
      f"{before['through_sequence']} -> {after['through_sequence']})")
PY
  echo "    snapshots in $ROOT/snapshot-{before,after}.json"
  ;;

attach)
  exec env CMUX_REMOTE_STATE_DIR="$CLIENT_STATE" "$BIN" remote connect "$(route)"
  ;;

down)
  for pid in connect daemon; do
    [[ -s "$ROOT/$pid.pid" ]] && kill "$(cat "$ROOT/$pid.pid")" 2>/dev/null || true
  done
  rm -rf "$ROOT"
  echo "removed $ROOT"
  ;;
esac
