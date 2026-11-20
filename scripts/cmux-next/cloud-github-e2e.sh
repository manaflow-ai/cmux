#!/bin/sh
# GitHub on a fresh cmux Cloud machine, through the team's GitHub connection, with no setup on the
# machine (plans/cmux-next/cloud-github-auth-DESIGN.md; HQ docs/design/remote-integrations.md).
# Run it ON the machine, as its work user (`cmux machine exec ID -- sh -s REPO < this file`):
#
#   cloud-github-e2e.sh OWNER/REPO        the live check: gh auth status, git push of a test branch
#                                         (deleted again), one GitHub MCP tool call, nothing at rest
#   cloud-github-e2e.sh --stub            the same wiring against a stub minter and a stub GitHub MCP
#                                         server, for a team with no GitHub connection yet
#
# Prints one `e2e: NAME ok|FAIL ...` line per check and exits 1 if any failed. It never prints a token.
set -u
umask 077
PATH="/opt/cmux/github/bin:/opt/cmux/current/bin:$PATH"
export PATH GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1
fails=0
say() { echo "e2e: $*"; }
check() { name=$1; shift; if "$@"; then say "$name ok"; else say "$name FAIL"; fails=$((fails+1)); fi; }
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

# The acpmux that serves `github-mcp`: on PATH, else inside cmux-tui (`cmux-tui acp`).
if command -v acpmux >/dev/null 2>&1; then acpmux_cmd=acpmux
elif [ -x "$HOME/.cmux/bin/cmux-tui" ]; then acpmux_cmd="$HOME/.cmux/bin/cmux-tui acp"
else acpmux_cmd="cmux-tui acp"; fi

# One MCP exchange with `acpmux github-mcp`: initialize, tools/list, then $1 as tools/call params.
mcp_call() {
  printf '%s\n%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":$1}" |
    (cd "$2" && timeout 120 $acpmux_cmd github-mcp)
}
# The id-3 reply is a result without isError.
mcp_ok() { grep '"id":3' | grep -q '"result"' && ! grep '"id":3' "$1" | grep -q '"isError":true'; }

if [ "${1:-}" = "--stub" ]; then
  command -v python3 >/dev/null || { say "stub FAIL no python3"; exit 1; }
  sock="$work/minter.sock"; log="$work/asks.log"
  # A minter that answers the agent socket's protocol with a fake installation token, and a GitHub
  # MCP server on loopback that takes only that token.
  python3 - "$sock" "$log" <<'PY' &
import json, os, socket, sys, threading, http.server
sock_path, log = sys.argv[1], sys.argv[2]
TOKEN = "ghs" + "_" + "stub" * 8 + "00"  # built at runtime: the script itself holds no token-shaped text
s = socket.socket(socket.AF_UNIX); s.bind(sock_path); s.listen(8)
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        if self.headers.get("authorization") != "Bearer " + TOKEN:
            self.send_response(401); self.end_headers(); return
        if "id" not in body:
            self.send_response(202); self.end_headers(); return
        m = body.get("method")
        result = {"tools": [{"name": "list_branches", "annotations": {"readOnlyHint": True}}]} if m == "tools/list" \
            else {"content": [{"type": "text", "text": "[{\"name\":\"main\"}]"}]} if m == "tools/call" else {"capabilities": {}}
        out = json.dumps({"jsonrpc": "2.0", "id": body["id"], "result": result}).encode()
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out))); self.end_headers(); self.wfile.write(out)
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(log + ".port", "w").write(str(srv.server_address[1]))
threading.Thread(target=srv.serve_forever, daemon=True).start()
while True:
    c, _ = s.accept(); line = c.makefile().readline()
    with open(log, "a") as f: f.write(json.dumps(json.loads(line).get("github_token", {}).get("permissions", {})) + "\n")
    c.sendall((json.dumps({"ok": True, "token": TOKEN}) + "\n").encode()); c.close()
PY
  stub=$!
  trap 'kill $stub 2>/dev/null; rm -rf "$work"' EXIT
  i=0; while [ ! -S "$sock" ] || [ ! -f "$log.port" ]; do i=$((i+1)); [ $i -gt 50 ] && break; sleep 0.1; done
  export ACPMUX_GITHUB_MCP_SOCKET="$sock" ACPMUX_GITHUB_MCP_ORIGIN="http://127.0.0.1:$(cat "$log.port")"
  mkdir -p "$work/repo" && git -C "$work/repo" init -q && git -C "$work/repo" remote add origin https://github.com/acme/app.git
  out="$work/mcp.out"
  mcp_call '{"name":"list_branches","arguments":{"owner":"acme","repo":"app"}}' "$work/repo" >"$out" 2>"$work/mcp.err"
  check mcp_call mcp_ok "$out" <"$out"
  check mcp_read_set grep -q '"contents": "read"' "$log"
  check no_token_in_reply sh -c "! grep -q ghs_ '$out'"
  say "stub: the minter and GitHub here are stand-ins; the live check needs the team's GitHub connection"
  exit $((fails > 0))
fi

repo=${1:?usage: cloud-github-e2e.sh OWNER/REPO | --stub}
check gh_auth_status gh auth status --hostname github.com
git clone -q --depth 1 "https://github.com/$repo.git" "$work/repo" 2>"$work/clone.err"
check git_clone test -d "$work/repo/.git"
branch="cmux-e2e/$(hostname)-$$"
if [ -d "$work/repo/.git" ]; then
  git -C "$work/repo" -c user.name=cmux-e2e -c user.email=e2e@cmux.invalid commit -q --allow-empty -m "cmux Cloud GitHub e2e"
  check git_push git -C "$work/repo" push -q origin "HEAD:refs/heads/$branch"
  git -C "$work/repo" push -q origin --delete "$branch" 2>/dev/null || say "cleanup: could not delete $branch"
fi
owner=${repo%/*}; name=${repo#*/}
out="$work/mcp.out"
mkdir -p "$work/repo"
mcp_call "{\"name\":\"list_branches\",\"arguments\":{\"owner\":\"$owner\",\"repo\":\"$name\"}}" "$work/repo" >"$out" 2>"$work/mcp.err"
check mcp_call mcp_ok "$out" <"$out"
grep '"id":3' "$out" | grep -o '"text":"[^"]\{0,160\}' | head -n 1 | sed 's/^/e2e: mcp says /' | grep -v ghs_
# Nothing at rest: no installation token anywhere the work user or the system keeps files.
check no_token_at_rest sh -c "! grep -rIl 'ghs_[A-Za-z0-9_]\{20,\}' \"\$HOME\" /etc /tmp 2>/dev/null | grep -v '^$work' | grep -q ."
exit $((fails > 0))
