#!/bin/sh
# GitHub on a fresh cmux Cloud machine, through the team's GitHub connection, with no setup on the
# machine (plans/cmux-next/cloud-github-auth-DESIGN.md; HQ docs/design/remote-integrations.md).
# Run it ON the machine, as its work user (`cmux machine exec ID -- sh -s REPO < this file`):
#
#   cloud-github-e2e.sh OWNER/REPO        the live cells, in a dedicated sandbox repository: the repo
#                                         reads as private, clone, branch, commit, push, a draft PR,
#                                         a PR comment read back, the PR's checks read, one GitHub MCP
#                                         tool call; then the PR is closed, the branch deleted, and
#                                         nothing is at rest
#   cloud-github-e2e.sh --agent-pr OWNER/REPO BRANCH FILE [LINE]
#                                         reads back what an agent was asked to do (the journey's
#                                         "GitHub by the agent (live)"): BRANCH exists, FILE is on it
#                                         (holding the one line LINE, when given), an open draft PR
#                                         from it; then closes that PR and deletes BRANCH, whatever
#                                         the checks said
#   cloud-github-e2e.sh --stub            the same wiring against a stub minter and a stub GitHub MCP
#                                         server, for a team with no GitHub connection yet
#
# Prints one `e2e: NAME ok|FAIL ...` line per cell and exits 1 if any failed. It never prints a token.
# CMUX_E2E_GITHUB_ORIGIN (default https://github.com), CMUX_E2E_ACPMUX and CMUX_E2E_REST_DIRS are for its own tests
# (scripts/cmux-next/cloud-journey-github.test.ts).
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
if [ -n "${CMUX_E2E_ACPMUX:-}" ]; then acpmux_cmd=$CMUX_E2E_ACPMUX
elif command -v acpmux >/dev/null 2>&1; then acpmux_cmd=acpmux
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
  # A read_set FAIL says what the minter was asked (permission sets only, never a token), which
  # acpmux answered, and the origin as git resolves it (an insteadOf rewrite changes it). Runs
  # 45750510949 and 45778908629 failed here on updated spares with nothing to go on.
  if ! grep -q '"contents": "read"' "$log" 2>/dev/null; then
    asks=$( { tr '\n' ' ' <"$log"; } 2>/dev/null | grep -v ghs_ | cut -c1-400)
    # shellcheck disable=SC2086 # the command is split on purpose
    set -- $acpmux_cmd
    say "mcp_read_set says asks: ${asks:-none}"
    say "mcp_read_set says acpmux: $(command -v "$1" 2>/dev/null || echo "$1") ($acpmux_cmd)"
    say "mcp_read_set says origin: $(git -C "$work/repo" remote get-url origin 2>&1 | head -n 1) (configured $(git -C "$work/repo" config --get remote.origin.url))"
    [ -s "$work/mcp.err" ] && sed -n '1,2p' "$work/mcp.err" | grep -v ghs_ | sed 's/^/e2e: mcp_read_set says acpmux: /'
  fi
  check no_token_in_reply sh -c "! grep -q ghs_ '$out'"
  say "stub: the minter and GitHub here are stand-ins; the live check needs the team's GitHub connection"
  exit $((fails > 0))
fi

origin=${CMUX_E2E_GITHUB_ORIGIN:-https://github.com}
valid_repo() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'; }
valid_ref() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._/-]+$'; }
# Nothing at rest: no installation token anywhere the work user or the system keeps files.
# CMUX_E2E_REST_DIRS narrows the scan for the script's own tests.
# shellcheck disable=SC2086 # the list is split on purpose
no_token_at_rest() { ! grep -rIl 'ghs_[A-Za-z0-9_]\{20,\}' ${CMUX_E2E_REST_DIRS:-"$HOME" /etc /tmp} 2>/dev/null | grep -v "^$work" | grep -q .; }
# The first two lines of a cell's stderr, so a FAIL says why (never a token).
why() { [ -s "$work/$1.err" ] && sed -n '1,2p' "$work/$1.err" | grep -v ghs_ | sed "s/^/e2e: $1 says /"; return 0; }
close_pr() { gh pr close "$1" --comment "cmux Cloud e2e: closed by the journey" >/dev/null 2>"$work/close.err"; }
delete_branch() { gh api -X DELETE "repos/$repo/git/refs/heads/$1" >/dev/null 2>"$work/delete.err"; }

if [ "${1:-}" = "--agent-pr" ]; then
  repo=${2:-}; branch=${3:-}; file=${4:-}; line=${5:-}
  if ! valid_repo "$repo" || ! valid_ref "$branch" || ! valid_ref "$file" || ! printf '%s' "$line" | grep -Eq '^[A-Za-z0-9 ._-]*$'; then
    say "agent_pr FAIL usage: cloud-github-e2e.sh --agent-pr OWNER/REPO BRANCH FILE [LINE]"; exit 1
  fi
  export GH_REPO="$repo"
  agent_branch() { gh api "repos/$repo/branches/$branch" --jq .name >/dev/null 2>"$work/branch.err"; }
  # The file as committed on the branch (raw), kept for the content cell.
  agent_commit() { gh api -H "Accept: application/vnd.github.raw" "repos/$repo/contents/$file?ref=$branch" >"$work/agent-file" 2>"$work/commit.err"; }
  # The one line asked for: the file, its carriage returns and trailing blank lines dropped, is exactly LINE.
  agent_content() { [ "$(tr -d '\r' <"$work/agent-file")" = "$line" ]; }
  agent_pr_draft() { [ "$(gh pr view "$pr" --json isDraft --jq .isDraft 2>"$work/draft.err")" = true ]; }
  check agent_branch agent_branch; why branch
  check agent_commit agent_commit; why commit
  if [ -n "$line" ]; then check agent_content agent_content; fi
  pr=$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty' 2>"$work/pr.err")
  check agent_pr test -n "$pr"; why pr
  if [ -n "$pr" ]; then say "agent_pr number $pr"; check agent_pr_draft agent_pr_draft; why draft; fi
  # The cleanup is the journey's, not the agent's: close what it opened and delete its branch.
  if [ -n "$pr" ]; then check pr_close close_pr "$pr"; why close; fi
  check branch_delete delete_branch "$branch"; why delete
  check no_token_at_rest no_token_at_rest
  exit $((fails > 0))
fi

repo=${1:?usage: cloud-github-e2e.sh OWNER/REPO | --agent-pr OWNER/REPO BRANCH FILE [LINE] | --stub}
valid_repo "$repo" || { say "repo FAIL not OWNER/REPO"; exit 1; }
# gh through the image's shim mints for this one repo; GH_REPO names it outside a checkout.
export GH_REPO="$repo"
# Not a cell: `gh auth status` is one of the commands the shim hands to the real gh untouched
# (cloud-github-auth-DESIGN.md 3.2), so with no gh login of the person's own it exits 1.
gh auth status --hostname github.com >/dev/null 2>&1; say "gh_auth_status info exit $?"
repo_private() { [ "$(gh repo view "$repo" --json isPrivate --jq .isPrivate 2>"$work/view.err")" = true ]; }
check repo_private repo_private; why view
git clone -q "$origin/$repo.git" "$work/repo" 2>"$work/clone.err"
check clone test -d "$work/repo/.git"; why clone
branch="cmux-e2e/$(hostname | tr -cd 'A-Za-z0-9-' | cut -c1-40)-$$"
file="cmux-e2e/$(printf '%s' "$branch" | tr '/' '-').md"
if [ -d "$work/repo/.git" ]; then
  base=$(git -C "$work/repo" symbolic-ref --short HEAD 2>/dev/null || echo main)
  check branch git -C "$work/repo" checkout -q -b "$branch"
  mkdir -p "$work/repo/cmux-e2e"
  echo "cmux Cloud GitHub e2e at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$work/repo/$file"
  commit() { git -C "$work/repo" add "$file" && git -C "$work/repo" -c user.name=cmux-e2e -c user.email=e2e@cmux.invalid commit -q -m "cmux Cloud GitHub e2e"; }
  check commit commit
  check push git -C "$work/repo" push -q origin "HEAD:refs/heads/$branch" 2>"$work/push.err"; why push
  url=$(cd "$work/repo" && gh pr create --draft --base "$base" --head "$branch" \
    --title "cmux Cloud GitHub e2e ($branch)" --body "Opened by the cmux Cloud journey, which closes it and deletes the branch." 2>"$work/pr.err")
  pr=$(printf '%s' "$url" | sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p' | head -n 1)
  check pr_create test -n "$pr"; why pr
  if [ -n "$pr" ]; then
    say "pr_create number $pr"
    marker="cmux-e2e-comment-$$"
    gh pr comment "$pr" --body "$marker" >/dev/null 2>"$work/comment.err"
    comments_read() { gh api "repos/$repo/issues/$pr/comments" --jq '.[].body' 2>>"$work/comment.err" | grep -qx "$marker"; }
    check pr_comments_read comments_read; why comment
    sha=$(git -C "$work/repo" rev-parse HEAD)
    runs=$(gh api "repos/$repo/commits/$sha/check-runs" --jq .total_count 2>"$work/checks.err")
    state=$(gh api "repos/$repo/commits/$sha/status" --jq .state 2>>"$work/checks.err")
    check pr_checks_read test -n "$runs" -a -n "$state"; why checks
    say "pr_checks check_runs=${runs:-?} status=${state:-?}"
    check pr_close close_pr "$pr"; why close
  fi
  check branch_delete git -C "$work/repo" push -q origin --delete "$branch" 2>"$work/delete.err"; why delete
fi
owner=${repo%/*}; name=${repo#*/}
out="$work/mcp.out"
mkdir -p "$work/repo"
mcp_call "{\"name\":\"list_branches\",\"arguments\":{\"owner\":\"$owner\",\"repo\":\"$name\"}}" "$work/repo" >"$out" 2>"$work/mcp.err"
check mcp_call mcp_ok "$out" <"$out"
grep '"id":3' "$out" | grep -o '"text":"[^"]\{0,160\}' | head -n 1 | sed 's/^/e2e: mcp says /' | grep -v ghs_
check no_token_at_rest no_token_at_rest
exit $((fails > 0))
