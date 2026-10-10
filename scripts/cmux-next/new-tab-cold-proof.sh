#!/usr/bin/env bash
# new-tab-cold-proof.sh DIR TAG N (cx-9fl): N fresh launches of the tagged app in ~/ffre-cmp/DIR on the GUI host;
# each types "chrome://extensions" into the very first Cmd-T as soon as the control socket answers, then
# prints {cold_field, ok, state}. Kills only the app and daemon it started.
D=$1; T=$2; N=$3
cd ~/ffre-cmp
for k in $(seq 1 $N); do
  A="$HOME/ffre-cmp/$D/cmux DEV $T.app"
  CMUX_NEXT_NO_ACTIVATE=1 nohup "$A/Contents/MacOS/cmux DEV" > app-$T.out 2>&1 &
  P=$!
  for i in $(seq 1 300); do [ -S /tmp/cmux-debug-$T.sock ] && python3 -c "import json,socket; c=socket.socket(socket.AF_UNIX); c.connect('/tmp/cmux-debug-$T.sock'); c.sendall(b'{\"id\":1,\"method\":\"snapshot.get\",\"params\":{}}\n'); b=c.recv(100); assert b" 2>/dev/null && break; sleep 0.1; done
  python3 - "$T" <<'PY'
import json, socket, sys, time
T = sys.argv[1]
def rpc(m, p=None):
    c = socket.socket(socket.AF_UNIX); c.connect(f"/tmp/cmux-debug-{T}.sock"); c.sendall((json.dumps({"id": 1, "method": m, "params": p or {}}) + "\n").encode()); b = b""
    while not b.endswith(b"\n"): b += c.recv(1 << 22)
    return json.loads(b).get("result")
for _ in range(100):
    top = rpc("snapshot.get")["topology"]
    if top.get("windows"): break
    time.sleep(0.05)
w = top["windows"][0]["key"]
rpc("debug.key", {"key": "t", "modifiers": ["command"], "window": w})
for ch in "chrome://extensions": rpc("debug.key", {"key": ch, "window": w})
f = None
for _ in range(20):
    f = rpc("debug.new_tab", {"action": "field"}); time.sleep(0.25)
st = rpc("debug.new_tab", {"action": "state"}); print(json.dumps({"cold_field": f, "ok": (f or {}).get("text") == "chrome://extensions", "state": st}))
PY
  kill $P 2>/dev/null; sleep 3
  for p in $(pgrep -f "ffre-cmp/$D/cmux DEV $T.app"); do kill $p; done
  S=$(pgrep -f "session cmux-app-$T "); [ -n "$S" ] && kill $S
  sleep 1
done
