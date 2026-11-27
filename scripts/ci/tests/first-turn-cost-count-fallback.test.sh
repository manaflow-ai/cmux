#!/usr/bin/env bash
# The first-turn cost guard never blocks on the router (hq-6d 2026-10-16): the
# team subrouter answers count_tokens with 502 (Claude subscriptions are off
# for count_tokens; Bedrock has none). `first_turn_cost.py count` then
# estimates the tokens from the request bytes, says so in a WARNING line, and
# still fails a request over the limit. Runs on a build host (python3), never
# on a laptop.
# The guard's own lines are shown only when an assertion fails: the over-limit
# case prints "FIRST-TURN-COST FAIL" on purpose, and in a passing CI log that
# line reads as a red (10-21: two lanes reported FIRST-TURN-COST as a base red).
#   scripts/ci/tests/first-turn-cost-count-fallback.test.sh
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
tool="$root/Native/OptChat/optchat-chief/measure/first_turn_cost.py"
work="$(mktemp -d)"
stub_pid=""
cleanup() { if [[ -n "$stub_pid" ]]; then kill "$stub_pid" 2>/dev/null || true; fi; rm -rf "$work"; }
trap cleanup EXIT

# A router stand-in: every POST answers 502, as the subrouter's count_tokens does.
cat > "$work/stub.py" <<'PY'
import http.server, os, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        body = b"upstream request failed"
        self.send_response(502); self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1] + ".tmp", "w").write(str(s.server_address[1])); os.replace(sys.argv[1] + ".tmp", sys.argv[1])
s.serve_forever()
PY
python3 -I "$work/stub.py" "$work/port" &
stub_pid=$!
for _ in $(seq 1 100); do [[ -s "$work/port" ]] && break; sleep 0.1; done
[[ -s "$work/port" ]] || { echo "FAIL: the stub did not start" >&2; exit 1; }
url="http://127.0.0.1:$(cat "$work/port")"

# One recorded turn request of `pad` bytes of prompt that names a cmux MCP tool.
request() {
  local dir="$1" pad="$2"
  mkdir -p "$dir"
  python3 -I - "$dir/0001.req.json" "$pad" <<'PY'
import json, sys
head = {"method": "POST", "path": "/v1/messages", "headers": {"anthropic-version": "2023-06-01"}}
body = {"model": "claude-x", "tools": [{"name": "mcp__cmux__workspace_list", "input_schema": {"type": "object"}}],
        "messages": [{"role": "user", "content": "x" * int(sys.argv[2])}]}
open(sys.argv[1], "wb").write(json.dumps(head).encode() + b"\n" + json.dumps(body).encode())
PY
}

# Fails the test, showing the guard's output (indented, so no line starts like the guard's verdict).
fail() { echo "FAIL: $1; the guard printed:" >&2; sed 's/^/    | /' <<<"$out" >&2; exit 1; }

status=0
request "$work/small" 1000
out="$(python3 -I "$tool" count "$work/small" --url "$url" --limit 50000 2>&1)" || status=$?
[[ "$status" == 0 ]] || fail "a small request with a 502 router exits $status, not 0"
grep -q 'FIRST-TURN-COST WARNING .*count_tokens.*502.*estimate' <<<"$out" || fail "no WARNING line names the fallback"

status=0
request "$work/large" 400000
out="$(python3 -I "$tool" count "$work/large" --url "$url" --limit 50000 2>&1)" || status=$?
[[ "$status" == 1 ]] || fail "a request over the limit with a 502 router exits $status, not 1"
grep -q 'FIRST-TURN-COST FAIL' <<<"$out" || fail "no FAIL line over the limit"
echo "PASS first-turn-cost count fallback (a small request passes on the estimate; one over the limit fails, as expected)"
