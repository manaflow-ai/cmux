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
#      (Codex would refuse a command beside a url) and still starts;
#   5. a Codex chat over the entry `cmux acp desktop link --app codex` writes (acpmux's
#      server in guest mode, ACPMUX_MCP_GUEST=codex): Codex merges it into
#      cmux's, which still runs this build's server with ACPMUX_MCP_GUEST empty,
#      and the chat keeps its acpmux tools;
#   6. agents.cmuxMcp off beside a `cmux` entry in Claude Code's own settings
#      that runs `cmux mcp serve`: `cmux setup mcp` names it and its remove
#      line, and the server it runs for a chat (CMUX_AGENT_SESSION set) is the
#      off server;
#   7. a real Codex chat's own `cmux mcp serve` carries CMUX_AGENT_SESSION
#      (Codex passes a stdio server only its own env and an allowlist), so it
#      is an agent chat: run again with that env and the answer turned off
#      (with "mcp": {"enabled": true}, which serves a caller outside chats),
#      it is the off server;
#   8. agents.cmuxMcp off with "mcp": {"enabled": true} and the person's own
#      stdio `cmux` entry (the manual line) in Codex's config: cmux gives the
#      chat no `cmux`, Codex starts the person's entry, and cmux tells it the
#      chat's CMUX_AGENT_SESSION and CMUX_AGENT_TOOLS_ANSWER=off: it is the
#      off server;
#  11. the daemon's question to Codex (`codex mcp get cmux`) per Codex chat
#      start, from its log: each under 2 s;
#  10. the same off with "mcp": {"enabled": true}, and the person's own stdio
#      `cmux` entry in Claude Code's user config: a real Claude chat starts it
#      with the chat's CMUX_AGENT_SESSION, and it is the off server, as a
#      terminal Claude's is (mcp-launch-check.sh case 8);
#  12. skip on doubt: a Codex chat in a folder whose project file (in a
#      folder Codex does not trust) has an HTTP `cmux` entry gets no `cmux`
#      and still starts (Codex's answer does not show the file loads);
#   9. a second daemon in the scratch folder, linked as a peer: its own answer
#      is off (with "mcp": {"enabled": true}) and its Codex config has the
#      person's stdio entry; a Codex chat this daemon (answer on) starts there
#      runs that entry with CMUX_AGENT_TOOLS_ANSWER=on and gets cmux's tools.
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
# SECONDS COMMAND...: COMMAND's exit, or 124 once it ran SECONDS. A watchdog, not `alarm; exec`:
# Codex 0.160.1 survives SIGALRM, so its `exec` outlived the script. TERM, then KILL after 2 s.
timeout() {
  local s=$1; shift
  perl -e 'my $s = shift; my $pid = fork // die "fork: $!"; if (!$pid) { exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", $pid; for (1..20) { exit 124 if waitpid($pid, 1) > 0; select(undef, undef, undef, 0.1) }
                       kill "KILL", $pid; waitpid($pid, 0); exit 124 };
    alarm $s; waitpid($pid, 0); exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$s" "$@"
}
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
# Started as from a terminal Claude's shell, which carries that Claude's answer to cmux's tools
# (the `claude` shim): a stale `on` the daemon must not pass on. The off and ask checks below then
# show that the live setting decides.
CMUX_AGENT_TOOLS_ANSWER=on acp daemon run > "$D/daemon.log" 2>&1 &
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
start_chat() { # NAME HARNESS [FOLDER]: a chat the way the agent pane starts one, with a first prompt
  acp new -d -n "$1" -m "$2" --cwd "${3:-$D/work}" --policy approve-all "say hi" > "$D/$1.new" 2>&1
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
cmux, session = sys.argv[1:3]
want = sys.argv[3] if len(sys.argv) > 3 else None
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
        key = want or "CMUX_NEXT_CONFIG_FILE"
        settings = next((w.split("=", 1)[1] or "(empty)" for w in env.split() if w.startswith(key + "=")), "-")
print(len(found), settings)
PY
session_id() { acp --json session info "$1" 2>/dev/null | python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("sessionId",""))'; }
codex_servers() { python3 "$D/codex-servers.py" "$CMUX" "$(session_id "$1")" ${2:+"$2"}; } # NAME [ENV KEY]
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
rc=$?; check "agent chat [claude]: its MCP config has one server, cmux, this build's, with the app's settings file ($(basename "${cfg:-none}"))" $rc
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

# 7. The Codex chat's own `cmux mcp serve`, as Codex started it: the keys of its env that decide
# who calls, run again with the answer off and "mcp": {"enabled": true} (which serves a caller
# outside cmux's chats). An agent chat gets the off server.
cat > "$D/codex-env.py" <<'PY'
import re, subprocess, sys
cmux, session = sys.argv[1:]
for line in subprocess.run(["ps", "-Ao", "pid=,command="], capture_output=True, text=True).stdout.splitlines():
    pid, cmd = line.strip().split(None, 1)
    if not cmd.startswith(cmux + " mcp serve"):
        continue
    env = subprocess.run(["ps", "eww", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
    if f"CMUX_AGENT_SESSION={session}" not in env:
        continue
    keys = ["CMUX_AGENT_SESSION", "CMUX_MCP_TOOLS", "CMUX_NEXT_CONFIG_FILE", "ACPMUX_MCP_GUEST", "CMUX_AGENT_TOOLS_ANSWER"]
    for key in keys:
        m = re.search(r"(?:^| )" + key + r"=(\S*)", env)
        if m:
            print(f"{key}={m.group(1)}")
    break
PY
python3 "$D/codex-env.py" "$CMUX" "$(session_id gui-codex-on)" > "$D/codex-chat.env"
cp "$CMUX_NEXT_CONFIG_FILE" "$D/settings-on.json"
echo '{"agents": {"cmuxMcp": "off"}, "mcp": {"enabled": true}}' > "$CMUX_NEXT_CONFIG_FILE"
python3 - "$CMUX" "$D/codex-chat.env" <<'PY'
import json, os, subprocess, sys
cmux, envfile = sys.argv[1:]
pairs = dict(line.strip().split("=", 1) for line in open(envfile) if "=" in line)
assert pairs.get("CMUX_AGENT_SESSION"), f"the Codex chat's server has no CMUX_AGENT_SESSION: {pairs}"
env = {"HOME": os.environ["HOME"], "PATH": os.environ["PATH"], **pairs}
p = subprocess.Popen([cmux, "mcp", "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, env=env, text=True)
def ask(i, method, params):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n"); p.stdin.flush()
    while True:
        m = json.loads(p.stdout.readline())
        if m.get("id") == i: return m
init = ask(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "gui-check", "version": "1"}})
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); p.stdin.flush()
tools = [t["name"] for t in ask(2, "tools/list", {})["result"]["tools"]]
p.kill()
text = init["result"].get("instructions", "")
print(f"env {sorted(pairs)}; tools {tools}")
assert len(tools) == 1 and "agents.cmuxMcp on --confirm" in text, (tools, text[:200])
PY
check "agent chat [codex]: its own cmux mcp serve carries CMUX_AGENT_SESSION, so with the answer off it is the off server" $?
cp "$D/settings-on.json" "$CMUX_NEXT_CONFIG_FILE"

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
rc=$?; check "agent chat [codex] over a global cmux entry with enabled = false: runs this build's server ($got), never the person's ($(tr '\n' ' ' < "$L"))" $rc
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
# 12. Skip on doubt: a folder Codex does not trust whose project file has an HTTP `cmux` entry.
U=$D/untrusted; mkdir -p "$U/.codex"; git -C "$U" init -q
printf '[mcp_servers.cmux]\nurl = "http://127.0.0.1:9/mcp"\n' > "$U/.codex/config.toml"
"$CMUX" setup trust "$U" >/dev/null 2>&1
start_chat gui-codex-doubt codex "$U"
for _ in $(seq 1 40); do [ -n "$(session_id gui-codex-doubt)" ] && break; perl -e 'select(undef,undef,undef,0.5)'; done
names=$(servers_of gui-codex-doubt)
started=$(acp --json session info gui-codex-doubt 2>/dev/null | python3 -c 'import json,sys; print(bool(json.loads(sys.stdin.read() or "{}").get("agentSessionId")))')
running=$(codex_servers gui-codex-doubt)
ok=0
case " ${names%% | *} " in *" cmux "*) ok=1 ;; esac
[ "$started" = True ] && [ "$running" = "0 -" ] || ok=1
check "agent chat [codex] in a folder with an untrusted HTTP project cmux entry: no cmux (running: $running), the chat starts (thread: $started) (tool rows | harness: $names)" $ok
# 5. A Codex chat over the entry `cmux acp desktop link --app codex` writes into the (scratch) Codex
# config: acpmux's own server in guest mode. Codex merges it key by key into the `cmux` the chat
# passes, so the server is this build's `cmux mcp serve`, and ACPMUX_MCP_GUEST is sent empty.
acp desktop link --app codex > "$D/link.out" 2>&1
grep -q ACPMUX_MCP_GUEST "$CODEX_HOME/config.toml"
rc=$?; check "desktop link codex wrote its guest-mode cmux entry into the scratch Codex config ($(tr '\n' ' ' < "$D/link.out" | cut -c1-120))" $rc
start_chat gui-codex-link codex
for _ in $(seq 1 40); do [ "$(codex_servers gui-codex-link)" != "0 -" ] && break; perl -e 'select(undef,undef,undef,0.5)'; done
got=$(codex_servers gui-codex-link)
guest=$(codex_servers gui-codex-link ACPMUX_MCP_GUEST)
names=$(servers_of gui-codex-link)
ok=0
[ "$got" = "1 $CMUX_NEXT_CONFIG_FILE" ] && [ "$guest" = "1 (empty)" ] || ok=1
case " ${names%% | *} " in *" cmux "*) ;; *) ok=1 ;; esac
case "$names" in *acpmux*) ;; *) ok=1 ;; esac
check "agent chat [codex] over a desktop-link cmux entry: this build's server ($got), ACPMUX_MCP_GUEST sent empty ($guest), cmux and acpmux tools listed ($names)" $ok
cp "$D/codex-base.toml" "$CODEX_HOME/config.toml"

# `cmux mcp serve` run with the env keys in file $2 (KEY=VALUE lines) and settings file $3: "off"
# when it is the off server, else "on".
cat > "$D/serve-as.py" <<'PY'
import json, os, subprocess, sys
cmux, envfile, settings = sys.argv[1:]
pairs = dict(line.strip().split("=", 1) for line in open(envfile) if "=" in line)
env = {"HOME": os.environ["HOME"], "PATH": os.environ["PATH"], "CMUX_NEXT_CONFIG_FILE": settings, **pairs}
p = subprocess.Popen([cmux, "mcp", "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, env=env, text=True)
def ask(i, method, params):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n"); p.stdin.flush()
    while True:
        m = json.loads(p.stdout.readline())
        if m.get("id") == i: return m
init = ask(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "gui-check", "version": "1"}})
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); p.stdin.flush()
tools = [t["name"] for t in ask(2, "tools/list", {})["result"]["tools"]]
p.kill()
print("off" if tools == ["cmux_tools_off"] else "on")
PY
# The env keys that decide the caller, of the `cmux mcp serve` processes whose env has $2.
cat > "$D/serve-env.py" <<'PY'
import re, subprocess, sys
cmux, marker = sys.argv[1:]
for line in subprocess.run(["ps", "-Ao", "pid=,command="], capture_output=True, text=True).stdout.splitlines():
    pid, cmd = line.strip().split(None, 1)
    if not cmd.startswith(cmux + " mcp serve"):
        continue
    env = subprocess.run(["ps", "eww", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
    if marker not in env:
        continue
    for key in ["CMUX_AGENT_SESSION", "CMUX_AGENT_TOOLS_ANSWER", "CMUX_MCP_TOOLS"]:
        m = re.search(r"(?:^| )" + key + r"=(\S*)", env)
        if m:
            print(f"{key}={m.group(1)}")
    break
PY
# 8. Off with "mcp": {"enabled": true}, and the person's own stdio entry (the manual line) in
# Codex's user config: the entry Codex starts for the chat is told the chat and the answer.
cp "$CMUX_NEXT_CONFIG_FILE" "$D/settings-on.json"
echo '{"agents": {"cmuxMcp": "off"}, "mcp": {"enabled": true}}' > "$CMUX_NEXT_CONFIG_FILE"
printf '[mcp_servers.cmux]\ncommand = "%s"\nargs = ["mcp", "serve"]\n' "$CMUX" >> "$CODEX_HOME/config.toml"
start_chat gui-codex-manual codex
sid=$(session_id gui-codex-manual)
for _ in $(seq 1 60); do [ -s "$D/manual.env" ] && break; python3 "$D/serve-env.py" "$CMUX" "CMUX_AGENT_SESSION=$sid" > "$D/manual.env"; perl -e 'select(undef,undef,undef,0.5)'; done
got=$(python3 "$D/serve-as.py" "$CMUX" "$D/manual.env" "$CMUX_NEXT_CONFIG_FILE" 2>&1)
keys=$(tr '\n' ' ' < "$D/manual.env")
grep -q "^CMUX_AGENT_TOOLS_ANSWER=off$" "$D/manual.env" && [ "$got" = off ]
check "agent chat [codex], answer off, mcp.enabled true, the person's own stdio cmux entry: it gets the chat's keys ($keys) and is the off server ($got)" $?
cp "$D/codex-base.toml" "$CODEX_HOME/config.toml"
# 10. Still off with "mcp": {"enabled": true}: a real Claude chat over the person's own stdio entry
# in Claude Code's user config, a wrapper that records the env it starts with and runs this build's
# `cmux mcp serve`.
mkdir -p "$D/entry"
printf '#!/bin/sh\nenv | grep -E "^(CMUX_AGENT_SESSION|CMUX_AGENT_TOOLS_ANSWER|CMUX_MCP_TOOLS)=" > "%s"\nexec "%s" mcp serve\n' \
  "$D/entry.env" "$CMUX" > "$D/entry/cmux"
chmod +x "$D/entry/cmux"
printf '{"mcpServers":{"cmux":{"type":"stdio","command":"%s","args":[],"env":{}}}}' "$D/entry/cmux" \
  > "$CLAUDE_CONFIG_DIR/.claude.json"
rm -f "$D/entry.env"
start_chat gui-claude-manual claude
for _ in $(seq 1 60); do [ -s "$D/entry.env" ] && break; perl -e 'select(undef,undef,undef,0.5)'; done
got=$( [ -s "$D/entry.env" ] && python3 "$D/serve-as.py" "$CMUX" "$D/entry.env" "$CMUX_NEXT_CONFIG_FILE" 2>&1 )
keys=$(tr '\n' ' ' < "$D/entry.env" 2>/dev/null)
# The chat's session: the one whose Claude MCP config acpmux wrote last (`run/mcp/<session>.json`).
chat=$(ls -t "$ACPMUX_HOME"/run/mcp/ 2>/dev/null | head -1); chat=${chat%.json}
info=$(session_id gui-claude-manual)
grep -q "^CMUX_AGENT_SESSION=$chat$" "$D/entry.env" 2>/dev/null && [ -n "$chat" ] && [ "$got" = off ]
rc=$?; check "agent chat [claude], answer off, mcp.enabled true, the person's own stdio cmux entry: it starts with the chat's keys ($keys; the chat: $chat; session info: ${info:-none}) and is the off server ($got)" $rc
rm -f "$CLAUDE_CONFIG_DIR/.claude.json"
cp "$D/settings-on.json" "$CMUX_NEXT_CONFIG_FILE"

# 9. A second daemon (B), linked to this one (A) as a peer: B's own answer is off with
# "mcp": {"enabled": true}, its Codex config has the person's stdio entry. A Codex chat A (answer
# on) starts on B runs that entry with A's answer, on, and it gets cmux's tools.
B=$D/b; mkdir -p "$B/home/.codex" "$B/acpmux" "$B/home/.config/cmux"
cp "$D/codex-base.toml" "$B/home/.codex/config.toml"
printf '[mcp_servers.cmux]\ncommand = "%s"\nargs = ["mcp", "serve"]\n' "$CMUX" >> "$B/home/.codex/config.toml"
echo '{"agents": {"cmuxMcp": "off"}, "mcp": {"enabled": true}}' > "$B/home/.config/cmux/cmux-next.json"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 - "$B/acpmux/config.json" "$D/work" <<'PY'
import json, sys
json.dump({"webRoots": [sys.argv[2]], "webAskingModes": {"codex": ["read-only", "auto", "agent", "default", "ask", "full-access"]},
           "permissionPolicy": "ask"}, open(sys.argv[1], "w"))
PY
( env -u CODEX_HOME -u CMUX_NEXT_CONFIG_FILE HOME="$B/home" ACPMUX_HOME="$B/acpmux" ACPMUX_SOCKET="$B/acpmux/acpmux.sock" \
    "$CMUX" acp daemon run --listen "127.0.0.1:$port" --token peer-check > "$D/daemon-b.log" 2>&1 ) &
daemon_b=$!
trap 'acp daemon shutdown --end-agents >/dev/null 2>&1; kill "$daemon" "$daemon_b" 2>/dev/null' EXIT
for _ in $(seq 1 60); do [ -s "$B/acpmux/run/peer.token" ] && break; perl -e 'select(undef,undef,undef,0.5)'; done
python3 - "$ACPMUX_HOME/config.json" "$port" "$(cat "$B/acpmux/run/peer.token" 2>/dev/null)" <<'PY'
import json, os, sys
path, port, token = sys.argv[1:]
cfg = json.load(open(path)) if os.path.exists(path) else {}
cfg.setdefault("peers", {})["b"] = {"url": f"ws://127.0.0.1:{port}", "token": "peer-check", "peerToken": token.strip()}
json.dump(cfg, open(path, "w"))
PY
# A reads its peers as it starts: restart it on its new config.
acp daemon shutdown --end-agents > /dev/null 2>&1; wait "$daemon" 2>/dev/null
CMUX_AGENT_TOOLS_ANSWER=on acp daemon run > "$D/daemon2.log" 2>&1 &
daemon=$!
for _ in $(seq 1 60); do acp daemon status >/dev/null 2>&1 && break; perl -e 'select(undef,undef,undef,0.5)'; done
for _ in $(seq 1 40); do acp machine ls 2>/dev/null | grep -qi "^b .*\(connected\|online\|up\)" && break; perl -e 'select(undef,undef,undef,0.5)'; done
acp machine ls > "$D/machines.txt" 2>&1
acp new -d -n gui-codex-peer -m codex --machine b --cwd "$D/work" "say hi" > "$D/peer.new" 2>&1
for _ in $(seq 1 80); do [ -s "$D/peer.env" ] && break; python3 "$D/serve-env.py" "$CMUX" "CMUX_AGENT_TOOLS_ANSWER=on" > "$D/peer.env"; perl -e 'select(undef,undef,undef,0.5)'; done
got=$(python3 "$D/serve-as.py" "$CMUX" "$D/peer.env" "$B/home/.config/cmux/cmux-next.json" 2>&1)
keys=$(tr '\n' ' ' < "$D/peer.env")
grep -q "^CMUX_AGENT_SESSION=." "$D/peer.env" && [ "$got" = on ]
rc=$?; check "agent chat [codex] started on a peer whose own answer is off: the person's stdio entry there gets this Mac's answer ($keys) and cmux's tools ($got; $(head -c 160 "$D/peer.new" | tr '\n' ' '); machines: $(head -c 160 "$D/machines.txt" | tr '\n' ' '))" $rc

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

# 6. Off, beside a `cmux` entry that runs `cmux mcp serve` in Claude Code's own (scratch) settings.
answer off
leftover_of() { # the Claude row's leftover in `cmux setup mcp`, as JSON
  "$CMUX" setup mcp 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin); print(json.dumps(next(c for c in r["clients"] if c["id"] == "claude")["leftover"]))'
}
# This build's own manual line, added on purpose: not listed.
printf '{"mcpServers": {"cmux": {"type": "stdio", "command": "%s", "args": ["mcp", "serve"], "env": {}}}}\n' \
  "$CMUX" > "$CLAUDE_CONFIG_DIR/.claude.json"
got=$(leftover_of)
[ "$got" = null ]
check "cmux setup mcp leaves out this build's own manual line in Claude Code's settings ($got)" $?
# Another cmux's (a published package's): listed, with its remove line.
printf '{"mcpServers": {"cmux": {"type": "stdio", "command": "npx", "args": ["-y", "cmux", "mcp", "serve"], "env": {}}}}\n' \
  > "$CLAUDE_CONFIG_DIR/.claude.json"
got=$(leftover_of)
case "$got" in *'"remove": "claude mcp remove --scope user cmux"'*) ok=0 ;; *) ok=1 ;; esac
check "cmux setup mcp names another cmux's entry in Claude Code's settings and its remove line ($got)" $ok
python3 - "$CMUX" <<'PY'
import json, os, subprocess, sys
env = dict(os.environ, CMUX_AGENT_SESSION="gui-check-chat")
p = subprocess.Popen([sys.argv[1], "mcp", "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, env=env, text=True)
def ask(i, method, params):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n"); p.stdin.flush()
    while True:
        m = json.loads(p.stdout.readline())
        if m.get("id") == i: return m
init = ask(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "gui-check", "version": "1"}})
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); p.stdin.flush()
tools = [t["name"] for t in ask(2, "tools/list", {})["result"]["tools"]]
p.kill()
text = init["result"].get("instructions", "")
print(f"tools {tools}; instructions {text[:160]!r}")
assert len(tools) == 1 and "agents.cmuxMcp on --confirm" in text, (tools, text)
PY
check "agents.cmuxMcp off: the old entry's cmux mcp serve, started for an agent chat, is the off server" $?
rm -f "$CLAUDE_CONFIG_DIR/.claude.json"
# The daemon's question to Codex per Codex chat start (`codex mcp get cmux`, logged with its time).
times=$(cat "$D"/daemon*.log 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep 'codex mcp get cmux' | sed -n 's/.*ms=\([0-9]*\).*/\1/p' | tr '\n' ' ')
slow=1; [ -n "$times" ] && slow=0
for ms in $times; do [ "$ms" -lt 2000 ] || slow=1; done
check "codex mcp get per Codex chat start (ms): ${times:-none logged}" $slow
echo "scratch: $D"
exit $failed
