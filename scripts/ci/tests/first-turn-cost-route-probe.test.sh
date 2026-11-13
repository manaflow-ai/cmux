#!/usr/bin/env bash
# The real-model route check of the first-turn cost harness (2026-11-09): the old
# team subrouter answered 200 to /_subrouter/ready while every Claude request got
# "502 upstream request failed", so a real=1 run waited out each turn (fleet step
# 726586531902f9d3dbc4c654). `first_turn_cost.py probe` sends one tiny Claude
# Code shaped request (SR2 admits only Claude Code's user agent) and exits 3 on
# a 5xx; `count` forwards the recorded request's user agent, so SR2 counts.
#   scripts/ci/tests/first-turn-cost-route-probe.test.sh
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
tool="$root/Native/OptChat/optchat-chief/measure/first_turn_cost.py"
work="$(mktemp -d)"
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT

# mode 502: ready is 200, every POST 502. mode sr2: a POST without Claude Code's
# user agent is 404 (as SR2 answers), with it 200.
cat > "$work/stub.py" <<'PY'
import http.server, json, os, sys
mode = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def answer(self, code, body):
        self.send_response(code); self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        self.answer(200, b'{"ok": true}')
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        if mode == "502":
            return self.answer(502, b"upstream request failed")
        if not (self.headers.get("user-agent") or "").startswith("claude-cli/"):
            return self.answer(404, b'{"detail":"Not Found"}')
        if self.path.endswith("/count_tokens"):
            return self.answer(200, json.dumps({"input_tokens": 77}).encode())
        return self.answer(200, json.dumps({"type": "message", "content": [{"type": "text", "text": "ok"}]}).encode())
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1] + ".tmp", "w").write(str(s.server_address[1])); os.replace(sys.argv[1] + ".tmp", sys.argv[1])
s.serve_forever()
PY
start() {
  python3 -I "$work/stub.py" "$work/port-$1" "$1" >"$work/stub-$1.log" 2>&1 &
  pids+=($!)
  # 60 s: a cold runner's first python3 can take long (the fallback test allows 10 s).
  for _ in $(seq 1 600); do [[ -s "$work/port-$1" ]] && break; sleep 0.1; done
  [[ -s "$work/port-$1" ]] || { echo "FAIL: the $1 stub did not start:" >&2; sed 's/^/    | /' "$work/stub-$1.log" >&2; exit 1; }
}
fail() { echo "FAIL: $1; it printed:" >&2; sed 's/^/    | /' <<<"$out" >&2; exit 1; }

start 502
start sr2
bad="http://127.0.0.1:$(cat "$work/port-502")"
sr2="http://127.0.0.1:$(cat "$work/port-sr2")"

status=0
out="$(python3 -I "$tool" probe --url "$bad" --timeout 10 2>&1)" || status=$?
[[ "$status" == 3 ]] || fail "a route whose requests answer 502 probes with exit $status, not 3"
grep -q 'FIRST-TURN-COST the route .* answered 502' <<<"$out" || fail "no line names the 502"

status=0
out="$(python3 -I "$tool" probe --url "$sr2" --timeout 10 2>&1)" || status=$?
[[ "$status" == 0 ]] || fail "a route that admits Claude Code probes with exit $status, not 0 (no Claude Code user agent?)"

# A recorded Claude Code request: count forwards its user agent.
mkdir -p "$work/run"
python3 -I - "$work/run/0001.req.json" <<'PY'
import json, sys
head = {"method": "POST", "path": "/v1/messages",
        "headers": {"anthropic-version": "2023-06-01", "User-Agent": "claude-cli/2.1.300 (external, cli)"}}
body = {"model": "claude-x", "tools": [{"name": "mcp__cmux__workspace_list", "input_schema": {"type": "object"}}],
        "messages": [{"role": "user", "content": "hi"}]}
open(sys.argv[1], "wb").write(json.dumps(head).encode() + b"\n" + json.dumps(body).encode())
PY
status=0
out="$(python3 -I "$tool" count "$work/run" --url "$sr2" --limit 50000 2>&1)" || status=$?
[[ "$status" == 0 ]] || fail "count exits $status"
grep -q '"source": "count_tokens"' <<<"$out" || fail "count fell back to the estimate: the user agent was not forwarded"
echo "PASS first-turn-cost route probe (502 behind a 200 ready fails fast; Claude Code's user agent reaches SR2)"
