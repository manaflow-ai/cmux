#!/usr/bin/env bash
# Transport spike: run the cmux-tui remote daemon inside a Blaxel sandbox and
# attach to it from this machine over the sandbox's private preview WSS URL.
#
# This is the cmux-tui replacement for the cmuxd-remote injection path in
# web/services/vms/drivers/blaxel.ts, driven end to end with curl so the
# mechanics are visible. See docs/cloud-cmux-tui-daemon.md for the design.
#
#   scripts/spike-cmux-tui-blaxel.sh up       --name <sandbox> --binary <musl cmux-tui[.gz]>
#   scripts/spike-cmux-tui-blaxel.sh evidence --name <sandbox>
#   scripts/spike-cmux-tui-blaxel.sh attach   --name <sandbox>
#   scripts/spike-cmux-tui-blaxel.sh destroy  --name <sandbox>
#
# Requires: BL_API_KEY and BL_WORKSPACE in the environment (or ~/.secrets/blaxel.env),
# python3, curl, and a local cmux-tui client binary (CMUX_TUI_CLIENT, default
# `cmux-tui` on PATH) whose REMOTE_PROTOCOL_VERSION matches the injected binary.
#
# `up` creates the sandbox, injects the static x86_64-musl cmux-tui in base64
# chunks (the sandbox filesystem API caps request bodies well below the ~30 MB
# encoded binary), starts `server start --remote-ws` under the sandbox process
# supervisor, mints a private preview + token for the listener port, creates a
# single-use enrollment invitation in the VM, enrolls this machine, and
# approves the enrollment from the VM side. State lands in
# ~/.cache/cmux-tui-blaxel-spike/<name>/.
set -euo pipefail

CONTROL=https://api.blaxel.ai/v0
PORT=1337
SESSION=cloud
REMOTE_BIN=/usr/local/bin/cmux-tui

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
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "--name must be a single path component" >&2; exit 64; }
case "$cmd" in up|evidence|attach|destroy) ;; *) sed -n '3,12p' "$0"; exit 64 ;; esac

if [[ -z "${BL_API_KEY:-}" && -r "$HOME/.secrets/blaxel.env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.secrets/blaxel.env"
fi
: "${BL_API_KEY:?set BL_API_KEY}" "${BL_WORKSPACE:?set BL_WORKSPACE}"
CLIENT="${CMUX_TUI_CLIENT:-cmux-tui}"

STATE_ROOT="$HOME/.cache/cmux-tui-blaxel-spike/$NAME"
mkdir -p "$STATE_ROOT"
chmod 700 "$STATE_ROOT"
CLIENT_STATE="$STATE_ROOT/client-state"

api() { # method path [json-body-file]
  local method="$1" url="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" "$url" \
      -H "X-Blaxel-Authorization: Bearer $BL_API_KEY" \
      -H "X-Blaxel-Workspace: $BL_WORKSPACE" \
      -H 'Content-Type: application/json' --data-binary "@$body"
  else
    curl -fsS -X "$method" "$url" \
      -H "X-Blaxel-Authorization: Bearer $BL_API_KEY" \
      -H "X-Blaxel-Workspace: $BL_WORKSPACE"
  fi
}

json() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

sandbox_url() { api GET "$CONTROL/sandboxes/$NAME" | json 'd["metadata"]["url"]'; }

sbx_exec() { # command [timeout-seconds]
  local command="$1" timeout="${2:-60}" req="$STATE_ROOT/exec.json"
  python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1],"waitForCompletion":True,"timeout":int(sys.argv[2])}))' \
    "$command" "$timeout" > "$req"
  api POST "$(cat "$STATE_ROOT/sandbox-url")/process" "$req"
}

sbx_exec_ok() { # command [timeout] -> stdout; fails on nonzero exit
  local out
  out="$(sbx_exec "$@")"
  python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
code = d.get("exitCode") or 0
sys.stdout.write(d.get("stdout") or "")
if code != 0:
    sys.stderr.write(d.get("stderr") or "")
    sys.exit(code)
PY
}

route() {
  local preview token
  preview="$(cat "$STATE_ROOT/preview-url")"
  token="$(cat "$STATE_ROOT/preview-token")"
  printf 'wss://%s/v1/link?bl_preview_token=%s' "${preview#https://}" "$token"
}

case "$cmd" in
up)
  [[ -n "$BINARY" && -r "$BINARY" ]] || { echo "--binary must point at a readable x86_64-musl cmux-tui (optionally .gz)" >&2; exit 64; }

  echo "==> create sandbox $NAME"
  python3 -c 'import json,sys; print(json.dumps({"metadata":{"name":sys.argv[1]},"spec":{"runtime":{"image":"blaxel/base-image:latest","memory":4096,"ports":[{"name":"cmuxtui","protocol":"HTTP","target":int(sys.argv[2])}]}}}))' \
    "$NAME" "$PORT" > "$STATE_ROOT/create.json"
  api POST "$CONTROL/sandboxes" "$STATE_ROOT/create.json" > /dev/null
  sandbox_url > "$STATE_ROOT/sandbox-url"
  echo "    sandbox API: $(cat "$STATE_ROOT/sandbox-url")"

  echo "==> inject cmux-tui (gzip+base64, chunked)"
  if [[ "$BINARY" == *.gz ]]; then
    base64 -i "$BINARY" | tr -d '\n' > "$STATE_ROOT/binary.b64"
  else
    gzip -9 -c "$BINARY" | base64 | tr -d '\n' > "$STATE_ROOT/binary.b64"
  fi
  rm -f "$STATE_ROOT"/chunk-*
  split -b 8000000 "$STATE_ROOT/binary.b64" "$STATE_ROOT/chunk-"
  parts=()
  for chunk in "$STATE_ROOT"/chunk-*; do
    part="$(basename "$chunk")"
    parts+=("/tmp/tui.$part.b64")
    python3 -c 'import json,sys; print(json.dumps({"content":open(sys.argv[1]).read(),"permissions":"0600"}))' "$chunk" > "$chunk.json"
    api PUT "$(cat "$STATE_ROOT/sandbox-url")/filesystem//tmp/tui.$part.b64" "$chunk.json" > /dev/null
    echo "    uploaded $part"
  done
  sbx_exec_ok "cat ${parts[*]} | base64 -d | gunzip > $REMOTE_BIN && chmod 755 $REMOTE_BIN && rm ${parts[*]} && $REMOTE_BIN --version" 120

  echo "==> start remote daemon (session $SESSION, ws :$PORT)"
  python3 -c 'import json,sys; print(json.dumps({"name":"cmux-tui-daemon","command":"env HOME=/root TERM=xterm-256color "+sys.argv[1]+" server start --session "+sys.argv[2]+" --remote-ws 0.0.0.0:"+sys.argv[3]+" --remote-ws-insecure-bind","waitForCompletion":False,"keepAlive":True,"restartOnFailure":True,"maxRestarts":10}))' \
    "$REMOTE_BIN" "$SESSION" "$PORT" > "$STATE_ROOT/daemon.json"
  api POST "$(cat "$STATE_ROOT/sandbox-url")/process" "$STATE_ROOT/daemon.json" > /dev/null
  sbx_exec_ok "sleep 2; env HOME=/root $REMOTE_BIN server status --session $SESSION" 30

  echo "==> private preview + token for :$PORT"
  python3 -c "import json; print(json.dumps({'metadata':{'name':'cmuxtui'},'spec':{'port':$PORT,'public':False}}))" > "$STATE_ROOT/preview.json"
  api POST "$CONTROL/sandboxes/$NAME/previews" "$STATE_ROOT/preview.json" | json 'd["spec"]["url"]' > "$STATE_ROOT/preview-url"
  python3 -c 'import json,datetime; print(json.dumps({"spec":{"expiresAt":(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=12)).strftime("%Y-%m-%dT%H:%M:%SZ")}}))' > "$STATE_ROOT/token.json"
  api POST "$CONTROL/sandboxes/$NAME/previews/cmuxtui/tokens" "$STATE_ROOT/token.json" | json 'd["spec"]["token"]' > "$STATE_ROOT/preview-token"
  chmod 600 "$STATE_ROOT/preview-token"
  echo "    $(cat "$STATE_ROOT/preview-url")"

  echo "==> enroll this machine"
  sbx_exec_ok "env HOME=/root $REMOTE_BIN remote enroll create --session $SESSION --ttl 300 --json" 30 \
    | json 'd["uri"]' > "$STATE_ROOT/invitation"
  chmod 600 "$STATE_ROOT/invitation"
  CMUX_REMOTE_STATE_DIR="$CLIENT_STATE" "$CLIENT" remote connect "$(route)" \
    --invite-file "$STATE_ROOT/invitation" --device-name "spike-$(hostname -s)" --headless \
    > "$STATE_ROOT/connect.log" 2>&1 &
  echo $! > "$STATE_ROOT/connect.pid"
  for _ in $(seq 1 30); do
    pending="$(sbx_exec_ok "env HOME=/root $REMOTE_BIN remote enroll pending --session $SESSION --json" 30)"
    invitation_id="$(printf '%s' "$pending" | python3 -c 'import json,sys; p=json.load(sys.stdin); print(p[0]["invitation_id"] if p else "")')"
    if [[ -n "$invitation_id" ]]; then
      sbx_exec_ok "env HOME=/root $REMOTE_BIN remote enroll approve $invitation_id --session $SESSION --json" 30 > /dev/null
      echo "    approved enrollment $invitation_id"
      break
    fi
    sleep 2
  done
  [[ -n "${invitation_id:-}" ]] || { echo "enrollment was never requested; see $STATE_ROOT/connect.log" >&2; exit 1; }

  echo "==> done. attach interactively with:"
  echo "    $0 attach --name $NAME"
  ;;

evidence)
  ROUTE="$(route)"
  rpc() { CMUX_REMOTE_STATE_DIR="$CLIENT_STATE" "$CLIENT" remote rpc "$ROUTE"; }
  echo "==> spawn PTY bash in a remote workspace"
  ws="$(printf '%s\n' '{"type":"open-workspace","root":"/root"}' | rpc | json 'd["id"]')"
  proc="$(python3 -c 'import json,sys; print(json.dumps({"type":"spawn-process","workspace":sys.argv[1],"argv":["bash"],"cwd":None,"env":{},"io":{"type":"pty","cols":100,"rows":30,"term":"xterm-256color","eof":"control-d"},"lifetime":"detached"}))' "$ws" | rpc | json 'd["process"]')"
  echo "    process $proc"

  echo "==> write marker, snapshot"
  data="$(printf 'echo SPIKE-MARKER-42 $(uname -m)\n' | base64)"
  printf '%s\n' "{\"type\":\"write-process\",\"process\":\"$proc\",\"write_id\":1,\"data\":\"$data\",\"eof\":false}" | rpc > /dev/null
  sleep 1
  printf '%s\n' "{\"type\":\"snapshot-process-terminal\",\"process\":\"$proc\"}" | rpc > "$STATE_ROOT/snapshot-before.json"

  echo "==> SIGKILL the enrollment-era client link, connect fresh, write again, snapshot"
  [[ -s "$STATE_ROOT/connect.pid" ]] && kill -9 "$(cat "$STATE_ROOT/connect.pid")" 2>/dev/null || true
  data2="$(printf 'echo RECONNECTED-AFTER-DROP\n' | base64)"
  { printf '%s\n' "{\"type\":\"write-process\",\"process\":\"$proc\",\"write_id\":2,\"data\":\"$data2\",\"eof\":false}"; sleep 1; \
    printf '%s\n' "{\"type\":\"snapshot-process-terminal\",\"process\":\"$proc\"}"; } | rpc > "$STATE_ROOT/snapshot-after.json"
  python3 - "$STATE_ROOT/snapshot-after.json" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    d = json.loads(line)
    if d["type"] != "process-terminal-snapshot":
        continue
    s = d["snapshot"]
    print(f'through_sequence={s["through_sequence"]}')
    for row in s["rows"]:
        text = "".join(run.get("text", "") for run in (row.get("runs") or []))
        if text.strip():
            print(repr(text.rstrip()))
PY
  echo "    snapshots in $STATE_ROOT/snapshot-{before,after}.json"
  ;;

attach)
  exec env CMUX_REMOTE_STATE_DIR="$CLIENT_STATE" "$CLIENT" remote connect "$(route)"
  ;;

destroy)
  [[ -s "$STATE_ROOT/connect.pid" ]] && kill "$(cat "$STATE_ROOT/connect.pid")" 2>/dev/null || true
  api DELETE "$CONTROL/sandboxes/$NAME" > /dev/null && echo "deleted sandbox $NAME"
  ;;
esac
