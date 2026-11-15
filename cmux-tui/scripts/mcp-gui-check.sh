#!/usr/bin/env bash
# The cmux MCP server agent chats get (the agent pane's sessions, acpmux
# agent_tools.rs), from a cmux build's own acpmux daemon:
#
#   mcp-gui-check.sh --cmux PATH
#
# PATH is a cmux build's bundled CLI (Contents/Resources/bin/cmux). It runs that
# build's acpmux daemon (`cmux acp daemon run`) in a scratch folder (HOME,
# ACPMUX_HOME, the settings file, CLAUDE_CONFIG_DIR, CODEX_HOME), with the agents
# against dead endpoints, and starts a Claude Code and a Codex chat the way the
# agent pane does (`cmux acp new`):
#   1. agents.cmuxMcp on: each chat lists the one server `cmux` (this build's
#      `cmux mcp serve`, the scratch settings file); the Claude chat's MCP config
#      names it; that server, started as the chat starts it, answers tools/list
#      and a cmux tool call (cmux_docs);
#   2. agents.cmuxMcp off or unanswered: neither chat gets `cmux`;
#   3. a Codex chat over the person's own global `cmux` entry with
#      `enabled = false` still runs this build's server, never theirs;
#   4. a Codex chat over the person's own HTTP `cmux` entry gets no `cmux`
#      (Codex would refuse a command beside a url) and still starts.
# Needs `node`, `claude` and `codex` on PATH; no sign-in. Never run it on a
# person's laptop. Prints PASS or FAIL per check and exits 1 on any FAIL.
set -u
[ "${1:-}" = --cmux ] && [ -n "${2:-}" ] || { echo "usage: $0 --cmux PATH"; exit 2; }
CMUX=$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")
T=$(cd "${TMPDIR:-/tmp}" && pwd -P) || exit 2
D=$(mktemp -d "$T/mcp-gui.XXXXXX") || exit 2
D=$(cd "$D" && pwd -P) || exit 2
case "$D" in "$T"/mcp-gui.?*) ;; *) echo "refusing scratch folder $D"; exit 2 ;; esac
command -v node >/dev/null && command -v claude >/dev/null && command -v codex >/dev/null \
  || { echo "node, claude and codex must be on PATH"; exit 2; }
failed=0
check() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; failed=1; fi; }
timeout() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
mkdir -p "$D/home" "$D/acpmux" "$D/claude" "$D/codex" "$D/work"
export HOME=$D/home ACPMUX_HOME=$D/acpmux CLAUDE_CONFIG_DIR=$D/claude CODEX_HOME=$D/codex
export CMUX_NEXT_CONFIG_FILE=$D/home/.config/cmux/cmux-next-gui.json
export ACPMUX_SOCKET=$D/acpmux/acpmux.sock
case "$HOME$ACPMUX_HOME$CLAUDE_CONFIG_DIR$CODEX_HOME$CMUX_NEXT_CONFIG_FILE" in *"$D"*"$D"*"$D"*"$D"*"$D"*) ;; *) echo "refusing: state outside $D"; exit 2 ;; esac
mkdir -p "$(dirname "$CMUX_NEXT_CONFIG_FILE")"
unset CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID ACPMUX_SESSION_ID
# The agents ask dead endpoints: their MCP servers start first.
export ANTHROPIC_API_KEY=sk-dummy ANTHROPIC_BASE_URL=http://127.0.0.1:9 CODEX_API_KEY=sk-test DEAD_KEY=x
cat > "$CODEX_HOME/config.toml" <<'TOML'
model_provider = "dead"
[model_providers.dead]
name = "dead"
base_url = "http://127.0.0.1:9/v1"
env_key = "DEAD_KEY"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
TOML
cd "$D/work"
acp() { "$CMUX" acp "$@"; }
answer() { echo "{\"agents\": {\"cmuxMcp\": \"$1\"}}" > "$CMUX_NEXT_CONFIG_FILE"; }
answer on
"$CMUX" setup trust "$D/work" >/dev/null 2>&1
acp daemon run > "$D/daemon.log" 2>&1 &
daemon=$!
trap 'acp daemon shutdown --end-agents >/dev/null 2>&1; kill "$daemon" 2>/dev/null' EXIT
for _ in $(seq 1 60); do acp daemon status >/dev/null 2>&1 && break; perl -e 'select(undef,undef,undef,0.5)'; done
echo "cmux $("$CMUX" --version | head -1)"

# The chat's record (`session info`): its tool rows (the agent pane's tool list) and the MCP
# servers the harness itself reports loading (Claude Code reports them; Codex does not).
cat > "$D/servers.py" <<'PY'
import json, sys
s = json.loads(sys.stdin.read() or "{}")
rows = sorted(t["id"][4:] for t in s.get("tools") or [] if str(t.get("id", "")).startswith("mcp:"))
loaded = sorted(f"{m.get('name')}:{m.get('status')}" for m in s.get("mcpServers") or [])
print(" ".join(rows) + " | " + " ".join(loaded))
PY
servers_of() { # NAME: "<tool rows' servers> | <harness-reported servers and status>"
  acp --json session info "$1" 2>/dev/null | python3 "$D/servers.py"
}
start_chat() { # NAME HARNESS: a chat the way the agent pane starts one, with a first prompt
  acp new -d -n "$1" -m "$2" --cwd "$D/work" --policy approve-all "say hi" > "$D/$1.new" 2>&1
  for _ in $(seq 1 40); do [ "$(servers_of "$1")" != " | " ] && break; perl -e 'select(undef,undef,undef,0.5)'; done
  # Claude Code reports its MCP servers after it started them.
  [ "$2" = claude ] && for _ in $(seq 1 40); do case "$(servers_of "$1")" in *"| "?*) break ;; esac; perl -e 'select(undef,undef,undef,0.5)'; done
}

# 1. On
for harness in claude codex; do
  start_chat "gui-$harness-on" "$harness"
  names=$(servers_of "gui-$harness-on")
  rows=${names%% | *}
  case " $rows " in *" cmux "*) ok=0 ;; *) ok=1 ;; esac
  # Claude Code itself says it connected to `cmux`.
  if [ "$harness" = claude ]; then case " ${names#* | } " in *" cmux:connected "*) ;; *) ok=1 ;; esac; fi
  check "agent chat [$harness, agents.cmuxMcp on]: lists cmux (tool rows | harness: $names)" $ok
done
# The `cmux mcp serve` processes Codex runs for chat NAME (by the chat's session id in their env,
# under a codex app-server), as "<count> <settings file of the first>".
cat > "$D/codex-servers.py" <<'PY'
import subprocess, sys
cmux, session = sys.argv[1:]
procs = {}
for line in subprocess.run(["ps", "-Ao", "pid=,ppid=,command="], capture_output=True, text=True).stdout.splitlines():
    pid, ppid, cmd = line.strip().split(None, 2)
    procs[pid] = (ppid, cmd)
def ancestors(pid):
    seen = []
    while pid in procs and pid not in seen and pid != "1":
        seen.append(pid); pid = procs[pid][0]
    return [procs[p][1] for p in seen[1:]]
found, settings = [], "-"
for pid, (_, cmd) in procs.items():
    if not cmd.startswith(cmux + " mcp serve") or not any("app-server" in a for a in ancestors(pid)):
        continue
    env = subprocess.run(["ps", "eww", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
    if f"CMUX_AGENT_SESSION={session}" in env:
        found.append(pid)
        settings = next((w.split("=", 1)[1] for w in env.split() if w.startswith("CMUX_NEXT_CONFIG_FILE=")), "-")
print(len(found), settings)
PY
session_id() { acp --json session info "$1" 2>/dev/null | python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("sessionId",""))'; }
codex_servers() { python3 "$D/codex-servers.py" "$CMUX" "$(session_id "$1")"; }
got=$(codex_servers gui-codex-on)
[ "$got" = "1 $CMUX_NEXT_CONFIG_FILE" ]
check "agent chat [codex]: its app-server runs this build's cmux mcp serve with the app's settings file ($got)" $?
# The Claude chat's MCP config file: the one server definition.
cfg=$(grep -l '"cmux"' "$ACPMUX_HOME"/run/mcp/*.json 2>/dev/null | head -1)
python3 - "$cfg" "$CMUX" "$CMUX_NEXT_CONFIG_FILE" > "$D/cmux-server.json" <<'PY'
import json, sys
cfg, cmux, settings = sys.argv[1:]
servers = json.load(open(cfg))["mcpServers"]
assert list(servers) == ["cmux"], list(servers)
s = servers["cmux"]
assert s["command"] == cmux, s["command"]
assert s["args"][:2] == ["mcp", "serve"], s["args"]
assert s["env"].get("CMUX_NEXT_CONFIG_FILE") == settings, s["env"]
print(json.dumps(s))
PY
check "agent chat [claude]: its MCP config has one server, cmux, this build's, with the app's settings file ($(basename "${cfg:-none}"))" $?
# That server, started as the chat starts it: tools/list and a cmux tool call.
python3 - "$D/cmux-server.json" <<'PY'
import json, os, subprocess, sys
s = json.load(open(sys.argv[1]))
env = dict(os.environ); env.update(s.get("env", {}))
p = subprocess.Popen([s["command"], *s["args"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, env=env, text=True)
def ask(i, method, params):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n"); p.stdin.flush()
    while True:
        line = p.stdout.readline()
        if not line: raise SystemExit(f"no answer to {method}")
        m = json.loads(line)
        if m.get("id") == i: return m
init = ask(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "gui-check", "version": "1"}})
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); p.stdin.flush()
tools = [t["name"] for t in ask(2, "tools/list", {})["result"]["tools"]]
call = ask(3, "tools/call", {"name": "cmux_docs", "arguments": {"query": "workspace"}})
text = json.dumps(call.get("result", call))
p.kill()
print(f"server {init['result']['serverInfo']['name']}; tools {tools}; cmux_docs answered {len(text)} bytes")
assert init["result"]["serverInfo"]["name"] == "cmux" and tools, tools
assert "result" in call and not call["result"].get("isError"), call
PY
check "agent chat [claude]: its cmux server answers tools/list and a cmux tool call (cmux_docs)" $?

# 3. A Codex chat over the person's own global `cmux` entry, turned off, in a folder of its own:
# the chat's server is still this build's, on (cmux-codex-acp sends enabled and the session's cwd).
L=$D/person.log; : > "$L"
cat > "$D/person-mcp.js" <<'JS'
require("fs").appendFileSync(process.argv[2], "started person\n");
process.stdin.resume();
JS
mkdir -p "$D/person-cwd"
cp "$CODEX_HOME/config.toml" "$D/codex-base.toml"
printf '[mcp_servers.cmux]\ncommand = "%s"\nargs = ["%s", "%s"]\nenabled = false\ncwd = "%s"\n' \
  "$(command -v node)" "$D/person-mcp.js" "$L" "$D/person-cwd" >> "$CODEX_HOME/config.toml"
start_chat gui-codex-global codex
for _ in $(seq 1 40); do [ "$(codex_servers gui-codex-global)" != "0 -" ] && break; perl -e 'select(undef,undef,undef,0.5)'; done
got=$(codex_servers gui-codex-global)
[ "$got" = "1 $CMUX_NEXT_CONFIG_FILE" ] && [ ! -s "$L" ]
check "agent chat [codex] over a global cmux entry with enabled = false: runs this build's server ($got), never the person's ($(tr '\n' ' ' < "$L"))" $?
# 4. A Codex chat over the person's own HTTP `cmux` entry: no `cmux` (Codex would refuse a command
# beside a url), the chat still starts, the other servers stay.
cp "$D/codex-base.toml" "$CODEX_HOME/config.toml"
printf '[mcp_servers.cmux]\nurl = "http://127.0.0.1:9/mcp"\n' >> "$CODEX_HOME/config.toml"
start_chat gui-codex-http codex
for _ in $(seq 1 40); do [ -n "$(session_id gui-codex-http)" ] && break; perl -e 'select(undef,undef,undef,0.5)'; done
names=$(servers_of gui-codex-http)
started=$(acp --json session info gui-codex-http 2>/dev/null | python3 -c 'import json,sys; print(bool(json.loads(sys.stdin.read() or "{}").get("agentSessionId")))')
case " ${names%% | *} " in *" cmux "*) ok=1 ;; *) ok=0 ;; esac
running=$(codex_servers gui-codex-http)
[ "$started" = True ] && [ "$running" = "0 -" ] && case "$names" in *acpmux*) true ;; *) false ;; esac || ok=1
check "agent chat [codex] over an HTTP cmux entry: no cmux (running: $running), the chat starts (thread: $started), its other servers stay (tool rows | harness: $names)" $ok
cp "$D/codex-base.toml" "$CODEX_HOME/config.toml"

# 2. Off and unanswered
for value in off ask; do
  answer "$value"
  for harness in claude codex; do
    start_chat "gui-$harness-$value" "$harness"
    names=$(servers_of "gui-$harness-$value")
    case " ${names%% | *} ${names#* | } " in *" cmux "*|*" cmux:"*) ok=1 ;; *) ok=0 ;; esac
    # A read that found no tool rows proves nothing.
    case "$names" in " | "*) ok=1 ;; esac
    check "agent chat [$harness, agents.cmuxMcp $value]: no cmux (tool rows | harness: $names)" $ok
  done
done
echo "scratch: $D"
exit $failed
