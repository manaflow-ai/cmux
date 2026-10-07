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
BRAIN="$OUT/brain-$(date +%s)"
SOCK="$BRAIN/daemon/cmux.sock"
TOOLS="$BRAIN/mux/optchat/tools.sock"
mkdir -p "$BRAIN/daemon" "$BRAIN/mux" "$OUT"
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; }
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
env -i HOME="$HOME" PATH=/usr/bin:/bin:"$BIN" MUX_HOME="$BRAIN/mux" OPTCHAT_INSPECTOR=1 \
  "$BIN/optchat-chief" host --daemon-socket "$SOCK" --mux-home "$BRAIN/mux" >"$OUT/host.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 300); do [[ -S "$TOOLS" ]] && break; sleep 0.1; done
[[ -S "$TOOLS" ]] || { echo "the host served no tools socket"; tail -20 "$OUT/host.log"; exit 1; }

cli() { env -i HOME="$HOME" PATH=/usr/bin:/bin CMUX_SOCKET_PATH="$SOCK" "$BIN/cmux" "$@"; }
echo "== identify capability"
cli --json raw command --request-json '{"cmd":"identify"}' | python3 -c 'import json,sys; d=json.load(sys.stdin); print("chief-inspect-v1" in json.dumps(d))'
for req in '{"cmd":"chief-inspect","path":"/api/status"}' \
           '{"cmd":"chief-inspect","path":"/api/node","query":{"name":"0+8"}}' \
           '{"cmd":"chief-inspect","path":"/api/turn","query":{"key":"now"}}' \
           '{"cmd":"chief-inspect","path":"/api/ticket"}'; do
  echo "== $req"
  cli --json raw command --request-json "$req" 2>&1 | head -c 600; echo
done
