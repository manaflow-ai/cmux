#!/usr/bin/env bash
# scripts/ci/cmux-tui-tree-claim.sh against a stub OIDC issuer and a stub
# claim authority that grants the first claimant of a key and names it to
# every later one, as the controller does. Two claims at once: exactly one
# wins and both name the same owner. No authority: exit 3 (fall back).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'kill "${PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cat > "$TMP/server.py" <<'PY'
import json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
lock, owners = threading.Lock(), {}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):  # the OIDC token endpoint: the token is the run id
        run = self.headers["Authorization"].split()[-1]
        self.send_response(200); self.end_headers()
        self.wfile.write(json.dumps({"value": run}).encode())
    def do_POST(self):
        run = int(self.headers["Authorization"].split()[-1])
        key = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["key"]
        with lock:
            owner = owners.setdefault(key, run)
        self.send_response(200); self.end_headers()
        self.wfile.write(json.dumps({"owner_run_id": owner, "granted": owner == run}).encode())
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_port))
srv.serve_forever()
PY
python3 "$TMP/server.py" "$TMP/port" & PID=$!
for _ in $(seq 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
port=$(cat "$TMP/port")
key=bfbd3600debc620419a12d8685fab285bd7fe982
claim() {
  ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:$port/token?x=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN="$1" \
    CMUX_TUI_TREE_CLAIM_URL="http://127.0.0.1:$port/claim" "$ROOT/scripts/ci/cmux-tui-tree-claim.sh" "$key"
}
claim 101 > "$TMP/a" & A=$!
claim 102 > "$TMP/b" & B=$!
wait $A; wait $B
granted=$(cat "$TMP/a" "$TMP/b" | grep -c 'granted=true' || true)
[[ "$granted" == 1 ]] || fail "two claims at once: $granted winners ($(cat "$TMP/a" "$TMP/b"))"
[[ "$(cut -d' ' -f1 "$TMP/a")" == "$(cut -d' ' -f1 "$TMP/b")" ]] || fail "the claimants were told different owners"
owner=$(cut -d' ' -f1 "$TMP/a")
[[ "$(claim 103)" == "$owner granted=false" ]] || fail "a later claim did not name the owner"
set +e
CMUX_TUI_TREE_CLAIM_URL="http://127.0.0.1:1/claim" ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:$port/token?x=1" \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN=104 "$ROOT/scripts/ci/cmux-tui-tree-claim.sh" "$key" 2>/dev/null; rc=$?
env -u ACTIONS_ID_TOKEN_REQUEST_URL "$ROOT/scripts/ci/cmux-tui-tree-claim.sh" "$key" 2>/dev/null; rc2=$?
set -e
[[ "$rc" == 3 && "$rc2" == 3 ]] || fail "an unreachable authority or no OIDC token must exit 3 (got $rc, $rc2)"
echo "PASS: one tree claim wins at a time; no authority falls back (exit 3)"
