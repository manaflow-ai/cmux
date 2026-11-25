#!/usr/bin/env bash
# The cmux MCP server agents get when cmux starts them (agent_computer_use.rs,
# acpmux agent_tools.rs): one server, named `cmux`, through the launch, and no
# write to an agent's own config.
#
#   mcp-launch-check.sh [--cmux PATH]
#
# Needs `node`, `claude` and `codex` on PATH; no sign-in (each agent runs
# against a dead endpoint: its MCP servers start before the first request).
# Every config lives in a scratch folder (HOME, CLAUDE_CONFIG_DIR, CODEX_HOME):
# this account's own ~/.claude.json and ~/.codex are never read or written.
# Run it on a fleet Mac or a VM, never on a person's laptop.
#
# Without --cmux it checks the agents' own rules with fake servers that log
# which one started (`user`, `project`, `local`: the person's; `shim`: ours):
#   1. Claude Code: a --mcp-config server replaces a same-named entry of the
#      user, project (.mcp.json) and local scopes whole.
#   2. Codex: -c mcp_servers.cmux.{command,args,cwd,enabled=true,env.*} wins
#      over a person's own cmux entry (user layer, trusted project, --profile
#      file), even one turned off: only `shim` starts, the session reaches the
#      model request, and the entry's other keys stay (documented).
#   3. Codex: a person's HTTP server named cmux cannot take a command (Codex
#      refuses it), the reason the shim gives no server there.
# With --cmux PATH (a cmux build's bundled CLI) it runs that build's real
# shims and setup:
#   4. the claude shim: the agent's cmux is this build's server;
#   5. the codex shim (a fake `codex` first on PATH records the launch, the
#      real one then runs it): one cmux server, this build's, with no entry,
#      over another cmux's user entry, over a project entry; an HTTP cmux
#      entry gets no server and Codex still starts;
#   6. agents.cmuxMcp off: neither shim passes a server (no value or `ask` is on);
#   7. cmux setup mcp with the real claude and codex installed writes nothing
#      to their configs, names the manual lines, and refuses --remove;
#   8. agents.cmuxMcp off with "mcp": {"enabled": true} and the person's own
#      stdio cmux entry in Claude's user config: a real Claude through the
#      claude shim starts it with CMUX_AGENT_TOOLS_ANSWER=off, and it is the
#      off server (as a GUI Claude chat's is: mcp-gui-check.sh case 10);
#   9. the same with the entry in Codex's user config: the codex shim gives
#      the entry's own command and args and
#      `-c mcp_servers.cmux.env.CMUX_AGENT_TOOLS_ANSWER="off"`, a real Codex
#      starts, and the entry is the off server;
#  10-14. the review's five probes (an untrusted sub-folder, only a middle
#      folder trusted, a profile beside a project, a launch-folder key, a
#      submodule), with marker files: Codex with the shim's -c starts exactly
#      the server Codex alone starts, and starts; and the shim's question to
#      Codex (`mcp get`) per launch, timed;
#  15. Codex itself: env keys alone for an entry it does not load make it
#      refuse to start;
#  16-21. skip on doubt (codex_cmux_entry.rs), with the answer on: when cmux
#      cannot be sure what the launch loads, the shim adds no server and no
#      env keys, says nothing, and Codex starts with the person's config:
#      16. the trust prompt, driven in tmux: a new folder whose project file
#          has an HTTP cmux entry; the person trusts it at Codex's prompt and
#          Codex runs on (no "url is not supported for stdio");
#      17. `exec --trust` in that folder (Codex versions with --trust);
#      18. `exec -C <link>` whose trust key is the link's path;
#      19. resume, fork, --worktree and other launches: nothing recorded;
#      20. a resolver that does not answer in time: nothing, launch not held;
#      21. an untrusted project file beside a user stdio entry: nothing.
# JSON is read from stdout only: an agent may warn on stderr.
# Prints PASS or FAIL per check and exits 1 on any FAIL.
set -u
CMUX=""
[ "${1:-}" = --cmux ] && CMUX=$2
# A new scratch folder under the temporary folder, by its real path (/tmp is
# /private/tmp on macOS; project paths are matched as Codex resolves them).
# Everything below writes only there: refuse anything else.
T=$(cd "${TMPDIR:-/tmp}" && pwd -P) || exit 2
D=$(mktemp -d "$T/mcp-launch.XXXXXX") || exit 2
D=$(cd "$D" && pwd -P) || exit 2
case "$D" in "$T"/mcp-launch.?*) ;; *) echo "refusing scratch folder $D"; exit 2 ;; esac
NODE=$(command -v node) || { echo "node is not on PATH"; exit 2; }
CLAUDE=$(command -v claude) || { echo "claude is not on PATH"; exit 2; }
CODEX=$(command -v codex) || { echo "codex is not on PATH"; exit 2; }
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
mkdir -p "$D/home" "$D/claude" "$D/codex" "$D/work" "$D/bin"
export HOME=$D/home CLAUDE_CONFIG_DIR=$D/claude CODEX_HOME=$D/codex
case "$HOME$CLAUDE_CONFIG_DIR$CODEX_HOME" in *"$D"*"$D"*"$D"*) ;; *) echo "refusing: configs outside $D"; exit 2 ;; esac
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY
cd "$D/work"
F=$D/fake-mcp.js
cat > "$F" <<'JS'
// Logs that it started (its label), answers initialize and tools/list.
const fs = require("fs");
const [label, log] = process.argv.slice(2);
fs.appendFileSync(log, `started ${label}\n`);
let buf = "";
process.stdin.on("data", (d) => {
  buf += d;
  for (let i; (i = buf.indexOf("\n")) >= 0; ) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    if (msg.id === undefined) continue;
    const result = msg.method === "initialize"
      ? { protocolVersion: msg.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: label, version: "1" } }
      : msg.method === "tools/list" ? { tools: [] } : {};
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result }) + "\n");
  }
});
JS
L=$D/started.log; : > "$L"
json_srv() { printf '{"type":"stdio","command":"%s","args":["%s","%s","%s"]}' "$NODE" "$F" "$1" "$2"; }
claude_session() { # a -p session against a dead endpoint; its MCP servers start first
  ANTHROPIC_API_KEY=sk-dummy ANTHROPIC_BASE_URL=http://127.0.0.1:9 timeout 90 \
    "$@" -p "say hi" --debug-file "$D/claude.debug" >/dev/null 2>&1
}
# A person's own Codex entry LABEL named cmux, turned off, with settings of its own.
toml_entry() { # its own working folder, which exists, so it starts when turned on alone
  mkdir -p "$D/$1-cwd"
  printf '[mcp_servers.cmux]\ncommand = "%s"\nargs = ["%s", "%s", "%s"]\nenabled = false\ncwd = "%s"\nstartup_timeout_sec = 30\n[mcp_servers.cmux.env]\nUSER_ONLY = "from-%s"\n' \
    "$NODE" "$F" "$1" "$L" "$D/$1-cwd" "$1"
}
# Codex sessions against a dead model provider: MCP servers start first.
dead=(-c 'model_provider="dead"' -c 'model_providers.dead={name="dead",base_url="http://127.0.0.1:9/v1",env_key="DEAD_KEY",wire_api="responses",request_max_retries=0,stream_max_retries=0}')
session() { # FOLDER ARGS...: print "<what started>|<config refused: 0/1>|<reached the model request: 0/1>"
  local at=$1; shift; : > "$L"
  (cd "$at" && DEAD_KEY=x CODEX_API_KEY=sk-test timeout 20 "$CODEX" exec --json --skip-git-repo-check "${dead[@]}" "$@" "say hi" \
     < /dev/null > "$D/session.out" 2>&1)
  local refused=0 reached=0
  grep -qiE 'invalid transport|failed to load|not supported for stdio' "$D/session.out" && refused=1
  # `codex exec --json` reports each event as a line (exec_events.rs, 0.160.1
  # and 0.169.0): the turn starts, which asks the (dead) model, then fails.
  grep -q '"type":"turn.started"' "$D/session.out" && grep -qE '"type":"(turn.failed|error)"' "$D/session.out" && reached=1
  printf '%s|%s|%s' "$(sort -u "$L" | tr '\n' ' ')" "$refused" "$reached"
}
echo "claude $("$CLAUDE" --version)"
echo "codex $("$CODEX" --version)"

# 1. Claude Code
printf '{"mcpServers":{"cmux":%s}}' "$(json_srv user "$L")" > "$CLAUDE_CONFIG_DIR/.claude.json"
claude_session "$CLAUDE" --mcp-config "$(printf '{"mcpServers":{"cmux":%s}}' "$(json_srv shim "$L")")"
grep -qx "started shim" "$L" && ! grep -qx "started user" "$L"
rc=$?; check "claude: --mcp-config's cmux replaces the user-scope cmux ($(tr '\n' ' ' < "$L"))" $rc
echo '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"
printf '{"enableAllProjectMcpServers":true}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
printf '{"mcpServers":{"cmux":%s}}' "$(json_srv project "$L")" > "$D/work/.mcp.json"
: > "$L"; claude_session "$CLAUDE"; base=$(tr '\n' ' ' < "$L")
: > "$L"; claude_session "$CLAUDE" --mcp-config "$(printf '{"mcpServers":{"cmux":%s}}' "$(json_srv shim "$L")")"
[ "$base" = "started project " ] && grep -qx "started shim" "$L" && ! grep -qx "started project" "$L"
check "claude: --mcp-config's cmux replaces the project-scope (.mcp.json) cmux (alone: $base)" $?
rm "$D/work/.mcp.json"
"$CLAUDE" mcp add --scope local cmux -- "$NODE" "$F" local "$L" >/dev/null 2>&1
: > "$L"; claude_session "$CLAUDE"; base=$(tr '\n' ' ' < "$L")
: > "$L"; claude_session "$CLAUDE" --mcp-config "$(printf '{"mcpServers":{"cmux":%s}}' "$(json_srv shim "$L")")"
[ "$base" = "started local " ] && grep -qx "started shim" "$L" && ! grep -qx "started local" "$L"
check "claude: --mcp-config's cmux replaces the local-scope cmux (alone: $base)" $?
echo '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"

# 2. Codex: the shim's keys win over a person's own cmux entry, wherever it is.
ours=(-c "mcp_servers.cmux.command=\"$NODE\"" -c "mcp_servers.cmux.args=[\"$F\",\"shim\",\"$L\"]"
      -c "mcp_servers.cmux.cwd=\"$D/work\"" -c 'mcp_servers.cmux.enabled=true' -c 'mcp_servers.cmux.env.CMUX_X="1"')
# $P is a git repository, the project root; sessions start in $P/sub.
P=$D/proj; mkdir -p "$P/sub" "$P/.codex"; git -C "$P" init -q
for layer in user project profile; do
  : > "$CODEX_HOME/config.toml"; : > "$P/.codex/config.toml"; rm -f "$CODEX_HOME/work.config.toml"
  extra=()
  case $layer in
    user) toml_entry user > "$CODEX_HOME/config.toml" ;;
    project) toml_entry project > "$P/.codex/config.toml"
             printf '[projects."%s"]\ntrust_level = "trusted"\n' "$P" > "$CODEX_HOME/config.toml" ;;
    profile) toml_entry profile > "$CODEX_HOME/work.config.toml"; extra=(--profile work) ;;
  esac
  alone=$(session "$P/sub" ${extra[@]+"${extra[@]}"} -c "mcp_servers.cmux.enabled=true")
  with=$(session "$P/sub" ${extra[@]+"${extra[@]}"} "${ours[@]}")
  merged=$(cd "$P/sub" && "$CODEX" ${extra[@]+"${extra[@]}"} "${ours[@]}" mcp get cmux --json 2>/dev/null)
  [ "${alone%|*|*}" = "started $layer " ] && [ "$with" = "started shim |0|1" ] && echo "$merged" | python3 -c '
import json, sys
e = json.load(sys.stdin); t = e["transport"]
assert e["enabled"] and t["args"][1] == "shim" and t["cwd"].endswith("/work"), e
assert t["env"] == {"USER_ONLY": "from-" + sys.argv[1], "CMUX_X": "1"}, t["env"]' "$layer"
  check "codex: the shim's keys win over a $layer cmux entry that is off (alone with it on: '${alone%|*|*}', with the shim's: '$with'); its other env keys stay" $?
done
: > "$CODEX_HOME/config.toml"; : > "$P/.codex/config.toml"; rm -f "$CODEX_HOME/work.config.toml"

# 3. Codex: an HTTP cmux entry takes no command.
printf '[mcp_servers.cmux]\nurl = "http://127.0.0.1:9/mcp"\n' > "$CODEX_HOME/config.toml"
refusal=$("$CODEX" "${ours[@]}" mcp get cmux --json 2>&1 >/dev/null | grep -o 'url is not supported for stdio' | head -1)
[ "$refusal" = "url is not supported for stdio" ]
check "codex: a command over the person's HTTP cmux entry is refused ($refusal)" $?
: > "$CODEX_HOME/config.toml"

if [ -n "$CMUX" ]; then
  # The build's real shims. A listening socket stands in for the daemon's.
  sock=$D/d.sock
  "$NODE" -e 'require("net").createServer(()=>{}).listen(process.argv[1])' "$sock" &
  listener=$!
  # The listener ends with the script, however it ends.
  trap 'kill "$listener" 2>/dev/null' EXIT
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$sock" ] && break; perl -e 'select(undef,undef,undef,0.2)'; done
  settings=$D/home/.config/cmux/cmux-next-dev.json
  mkdir -p "$(dirname "$settings")"
  answer() { echo "{\"agents\": {\"cmuxMcp\": \"$1\"}}" > "$settings"; }
  answer on
  CLI=$(cd "$(dirname "$CMUX")" && pwd -P)/$(basename "$CMUX")
  shim_env=(CMUX_TUI_SOCKET="$sock" CMUX_TUI_TERMINAL_ID=term_1 CMUX_NEXT_CONFIG_FILE="$settings")
  # Codex's folder first: another codex beside claude would run in its place.
  base_path="$(dirname "$CODEX"):$(dirname "$CLAUDE"):$(dirname "$NODE"):/usr/bin:/bin"

  # 4. Claude
  : > "$L"
  printf '{"mcpServers":{"cmux":%s}}' "$(json_srv user "$L")" > "$CLAUDE_CONFIG_DIR/.claude.json"
  # `timeout` is a function here: it runs `env`, never the other way round.
  ANTHROPIC_API_KEY=sk-dummy ANTHROPIC_BASE_URL=http://127.0.0.1:9 timeout 90 env "${shim_env[@]}" PATH="$base_path" \
    "$CMUX" agent claude-wrapper -p "say hi" --debug-file "$D/shim.debug" >/dev/null 2>&1
  grep -q 'MCP server "cmux".*serverVersion":{"name":"cmux"' "$D/shim.debug" && ! grep -qx "started user" "$L"
  check "claude shim: the agent's one cmux is this build's server, not the user-scope entry" $?
  echo '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"

  # 5. Codex. A fake `codex` first on PATH records the launch's arguments.
  # Quoted for sh (single quotes; a ' inside becomes '\''): printf %q is bash's.
  sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
  # A fake `codex` first on PATH that records a launch's arguments; the shim's own question to
  # Codex (`mcp get cmux --json`, the person's own entry) goes to the real one.
  fake_codex() {
    printf '#!/bin/sh\ncase " $* " in *" mcp get cmux --json "*) exec %s "$@";; esac\nfor a in "$@"; do printf "%%s\\n" "$a"; done > %s\n' \
      "$(sq "$CODEX")" "$(sq "$D/codex-args")"
  }
  fake_codex > "$D/bin/codex.tmp"
  chmod +x "$D/bin/codex.tmp"; mv "$D/bin/codex.tmp" "$D/bin/codex"
  shim_path="$D/bin:$base_path"
  record() { # FOLDER ARGS...: the shim's launch, recorded in $D/codex-args
    rm -f "$D/codex-args"
    (cd "$1" && shift && env "${shim_env[@]}" PATH="$shim_path" "$CMUX" agent codex-wrapper "$@" >/dev/null 2>"$D/shim.err")
  }
  replay() { # FOLDER: the recorded launch's -c settings, run by the real codex as a session
    local recorded=() a v
    while IFS= read -r a; do [ "$a" = -c ] && { IFS= read -r v; recorded+=(-c "$v"); }; done < "$D/codex-args"
    session "$1" ${recorded[@]+"${recorded[@]}"}
  }
  for case_ in none user project; do
    : > "$CODEX_HOME/config.toml"; : > "$P/.codex/config.toml"
    case $case_ in
      user) toml_entry user > "$CODEX_HOME/config.toml" ;;
      project) toml_entry project > "$P/.codex/config.toml"
               printf '[projects."%s"]\ntrust_level = "trusted"\n' "$P" > "$CODEX_HOME/config.toml" ;;
    esac
    record "$P/sub" exec "say hi"
    names=$(sed -n 's/^mcp_servers\.\([^.=]*\)\..*/\1/p' "$D/codex-args" | sort -u | tr '\n' ' ')
    grep -qx "mcp_servers.cmux.command=\"$CLI\"" "$D/codex-args" && grep -qx 'mcp_servers.cmux.enabled=true' "$D/codex-args"
    recorded_ok=$?
    result=$(replay "$P/sub")
    [ "$names" = "cmux " ] && [ $recorded_ok = 0 ] && [ "$result" = "|0|1" ] && [ ! -s "$D/shim.err" ]
    check "codex shim [$case_ cmux entry]: one server, cmux, this build's (servers: $names); the person's entry never starts; Codex starts (started|refused|reached: $result)" $?
  done
  : > "$P/.codex/config.toml"
  printf '[mcp_servers.cmux]\nurl = "http://127.0.0.1:9/mcp"\n' > "$CODEX_HOME/config.toml"
  record "$P/sub" exec "say hi"
  result=$(replay "$P/sub")
  ! grep -q '^mcp_servers\.' "$D/codex-args" && grep -q '^hooks' "$D/codex-args" && [ "$result" = "|0|1" ] && [ ! -s "$D/shim.err" ]
  check "codex shim [HTTP cmux entry]: no server goes in, the hooks do, Codex starts ($result), nothing said" $?
  : > "$CODEX_HOME/config.toml"

  # 6. Off: neither shim passes a server.
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > %s\n' "$(sq "$D/claude-args")" > "$D/bin/claude"
  chmod +x "$D/bin/claude"
  for value in off; do
    answer "$value"
    record "$P/sub" exec "say hi"
    rm -f "$D/claude-args"
    (cd "$P/sub" && env "${shim_env[@]}" PATH="$shim_path" "$CMUX" agent claude-wrapper -p hi >/dev/null 2>&1)
    ! grep -q '^mcp_servers\.' "$D/codex-args" && ! grep -qx -- '--mcp-config' "$D/claude-args"
    check "agents.cmuxMcp $value: neither shim passes a cmux server" $?
  done
  rm -f "$D/bin/claude" "$D/bin/codex"

  # 8 and 9. Off with "mcp": {"enabled": true} (which serves a caller outside cmux), and the
  # person's own stdio `cmux` entry: a wrapper that records the env it starts with, then runs this
  # build's `cmux mcp serve`. A terminal agent's entry must get the answer, off, and so be the off
  # server, as in an agent chat.
  echo '{"agents": {"cmuxMcp": "off"}, "mcp": {"enabled": true}}' > "$settings"
  mkdir -p "$D/entry"
  printf '#!/bin/sh
env | grep -E "^(CMUX_AGENT_SESSION|CMUX_AGENT_TOOLS_ANSWER|CMUX_MCP_TOOLS)=" > %s
exec %s mcp serve
' \
    "$(sq "$D/entry.env")" "$(sq "$CLI")" > "$D/entry/cmux"
  chmod +x "$D/entry/cmux"
  serve_as() { # ENV FILE: "off" when `cmux mcp serve` with those keys and the settings is the off server
    python3 - "$CLI" "$1" "$settings" <<'PY'
import json, os, subprocess, sys
cmux, envfile, settings = sys.argv[1:]
pairs = dict(line.strip().split("=", 1) for line in open(envfile) if "=" in line)
env = {"HOME": os.environ["HOME"], "PATH": os.environ["PATH"], "CMUX_NEXT_CONFIG_FILE": settings, **pairs}
p = subprocess.Popen([cmux, "mcp", "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, text=True)
def ask(i, method, params):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n"); p.stdin.flush()
    while True:
        m = json.loads(p.stdout.readline())
        if m.get("id") == i: return m
ask(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "launch-check", "version": "1"}})
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); p.stdin.flush()
tools = [t["name"] for t in ask(2, "tools/list", {})["result"]["tools"]]
p.kill()
print("off" if tools == ["cmux_tools_off"] else "on")
PY
  }
  # 8. A real Claude through the `claude` shim, the entry in its user config (the GUI side is
  # mcp-gui-check.sh case 10).
  rm -f "$D/entry.env"
  printf '{"mcpServers":{"cmux":{"type":"stdio","command":"%s","args":[],"env":{}}}}' "$D/entry/cmux" \
    > "$CLAUDE_CONFIG_DIR/.claude.json"
  ANTHROPIC_API_KEY=sk-dummy ANTHROPIC_BASE_URL=http://127.0.0.1:9 timeout 90 env "${shim_env[@]}" PATH="$base_path" \
    "$CMUX" agent claude-wrapper -p "say hi" >/dev/null 2>&1
  got=$( [ -s "$D/entry.env" ] && serve_as "$D/entry.env" )
  keys=$(tr '\n' ' ' < "$D/entry.env" 2>/dev/null)
  grep -qx "CMUX_AGENT_TOOLS_ANSWER=off" "$D/entry.env" 2>/dev/null && [ "$got" = off ]
  rc=$?; check "claude shim, answer off, mcp.enabled true, the person's own stdio cmux entry: it starts with the answer ($keys) and is the off server ($got)" $rc
  echo '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"
  # 9. A real Codex with the shim's env-only -c, the entry in its user config.
  rm -f "$D/entry.env"
  printf '[mcp_servers.cmux]\ncommand = "%s"\nargs = []\n' "$D/entry/cmux" > "$CODEX_HOME/config.toml"
  fake_codex > "$D/bin/codex"
  chmod +x "$D/bin/codex"
  record "$P/sub" exec "say hi"
  rm -f "$D/bin/codex"
  given=$(grep '^mcp_servers\.' "$D/codex-args" | tr '\n' ' ')
  result=$(replay "$P/sub")
  got=$( [ -s "$D/entry.env" ] && serve_as "$D/entry.env" )
  keys=$(tr '\n' ' ' < "$D/entry.env" 2>/dev/null)
  want="mcp_servers.cmux.command=\"$D/entry/cmux\" mcp_servers.cmux.args=[] mcp_servers.cmux.env.CMUX_AGENT_TOOLS_ANSWER=\"off\" "
  [ "$given" = "$want" ] && [ "$result" = "|0|1" ] \
    && grep -qx "CMUX_AGENT_TOOLS_ANSWER=off" "$D/entry.env" 2>/dev/null && [ "$got" = off ]
  rc=$?; check "codex shim, answer off, the person's stdio cmux entry in the user config: its own command and args and the env key go in ($given), Codex starts ($result), the entry starts with the answer ($keys) and is the off server ($got)" $rc
  : > "$CODEX_HOME/config.toml"

  # 10 to 14. The review's five probes, with marker files: a person's own entry's server writes
  # `started <label>` to $L when Codex starts it. For each, Codex alone starts some server or
  # none; with the shim's -c (answer off) it must start exactly the same, and still start. The
  # shim asks Codex itself which entry loads, so it sends that entry back (its command and args,
  # with the env key) or nothing. Each probe also times the shim's question to Codex.
  marker_entry() { printf '[mcp_servers.cmux]\ncommand = "%s"\nargs = ["%s", "%s", "%s"]\n' "$NODE" "$F" "$1" "$L"; }
  trust() { printf '[projects."%s"]\ntrust_level = "%s"\n' "$(cd "$1" && pwd -P)" "${2:-trusted}"; }
  probe() { # NAME FOLDER [ARGS...]: Codex alone vs Codex with the shim's -c, in FOLDER
    local name=$1 folder=$2; shift 2
    local alone with recorded=() a v ms
    alone=$(session "$folder" "$@")
    fake_codex > "$D/bin/codex"; chmod +x "$D/bin/codex"
    rm -f "$D/codex-args"
    (cd "$folder" && env "${shim_env[@]}" CMUX_TUI_MCP_RESOLVE_TRACE=1 PATH="$shim_path" "$CMUX" agent codex-wrapper "$@" exec "say hi" >/dev/null 2>"$D/shim.err")
    rm -f "$D/bin/codex"
    ms=$(sed -n 's/^cmux-tui: codex mcp get cmux: \([0-9]*\) ms.*/\1/p' "$D/shim.err" | head -1)
    resolve_ms+=" ${ms:-?}"
    while IFS= read -r a; do [ "$a" = -c ] && { IFS= read -r v; recorded+=(-c "$v"); }; done < "$D/codex-args"
    with=$(session "$folder" "$@" ${recorded[@]+"${recorded[@]}"})
    given=$(printf '%s\n' ${recorded[@]+"${recorded[@]}"} | grep '^mcp_servers\.' | tr '\n' ' ')
    local started=${alone%%|*} entry
    entry=$(sed -n 's/^cmux-tui: codex mcp get cmux: [0-9]* ms (\(.*\))$/\1/p' "$D/shim.err" | head -1)
    # Skip on doubt: a project file Codex's answer does not show it loads sends nothing.
    [ "$with" = "$alone" ] && [ "${alone#*|}" = "0|1" ] \
      && case "$given" in
           '') [ -z "$started" ] || case "$entry" in Doubt*) true ;; *) false ;; esac ;;
           *CMUX_AGENT_TOOLS_ANSWER*) [ -n "$started" ] ;;
           *) false ;;
         esac
    rc=$?; check "probe [$name]: Codex alone ($alone) = with the shim's -c ($with); answer: ${entry:-?}; sent: ${given:-nothing}; codex mcp get took ${ms:-?} ms" $rc
  }
  resolve_ms=""
  Q=$D/probes; rm -rf "$Q"; mkdir -p "$Q"
  # (1) An untrusted sub-folder of a trusted repository, with an entry of its own.
  mkdir -p "$Q/p1/sub/.codex"; git -C "$Q/p1" init -q
  marker_entry p1-sub > "$Q/p1/sub/.codex/config.toml"
  { trust "$Q/p1"; trust "$Q/p1/sub" untrusted; } > "$CODEX_HOME/config.toml"
  probe "untrusted sub-folder" "$Q/p1/sub"
  # (2) Only a middle folder trusted: a user-config entry and one in the middle folder's project file.
  mkdir -p "$Q/p2/mid/leaf" "$Q/p2/mid/.codex"; git -C "$Q/p2" init -q
  marker_entry p2-mid > "$Q/p2/mid/.codex/config.toml"
  { marker_entry p2-user; trust "$Q/p2/mid"; } > "$CODEX_HOME/config.toml"
  probe "middle-only trust" "$Q/p2/mid/leaf"
  # (3) A --profile file's entry beside a trusted project's.
  mkdir -p "$Q/p3/.codex"; git -C "$Q/p3" init -q
  marker_entry p3-project > "$Q/p3/.codex/config.toml"
  trust "$Q/p3" > "$CODEX_HOME/config.toml"
  marker_entry p3-profile > "$CODEX_HOME/work.config.toml"
  probe "profile vs project" "$Q/p3" -p work
  rm -f "$CODEX_HOME/work.config.toml"
  # (4) A trust key on the launch folder only, the entry at the repository root.
  mkdir -p "$Q/p4/sub" "$Q/p4/.codex"; git -C "$Q/p4" init -q
  marker_entry p4-root > "$Q/p4/.codex/config.toml"
  trust "$Q/p4/sub" > "$CODEX_HOME/config.toml"
  probe "launch-folder key" "$Q/p4/sub"
  # (5) A submodule of a trusted repository, with an entry of its own.
  mkdir -p "$Q/p5/module/.codex" "$Q/p5/.git/modules/module"; git -C "$Q/p5" init -q
  printf 'gitdir: ../.git/modules/module\n' > "$Q/p5/module/.git"
  marker_entry p5-module > "$Q/p5/module/.codex/config.toml"
  trust "$Q/p5" > "$CODEX_HOME/config.toml"
  probe "submodule" "$Q/p5/module"
  : > "$CODEX_HOME/config.toml"
  # The shim's question to Codex, per terminal launch: under the 2 s limit each time.
  slow=0; for ms in $resolve_ms; do case "$ms" in ''|*[!0-9]*) slow=1 ;; *) [ "$ms" -lt 2000 ] || slow=1 ;; esac; done
  check "codex mcp get per terminal launch (ms):$resolve_ms" $slow
  # (6) The class Codex itself shows: env keys alone for an entry it does not load make it refuse
  # to start, the reason cmux sends only an entry Codex answers, and sends it whole.
  alone=$(session "$D" -c 'mcp_servers.cmux.env.CMUX_AGENT_TOOLS_ANSWER="off"')
  [ "${alone#*|}" != "0|1" ]
  rc=$?; check "codex: env keys alone for an entry it does not load make it refuse ($alone)" $rc
  answer on

  # 16 to 21. Skip on doubt, with the answer on.
  http_entry() { printf '[mcp_servers.cmux]\nurl = "http://127.0.0.1:9/mcp"\n'; }
  : > "$CODEX_HOME/config.toml"
  # Signed in with an API key (scratch CODEX_HOME), so the TUI's only first-run step is the trust prompt.
  printf '{"OPENAI_API_KEY":"sk-test"}\n' > "$CODEX_HOME/auth.json"
  # 16. The trust prompt. A new git folder, never trusted, whose project file has an HTTP cmux entry.
  N=$D/doubt/new; mkdir -p "$N/.codex"; git -C "$N" init -q; http_entry > "$N/.codex/config.toml"
  TMUX_BIN=$(command -v tmux || ls /opt/homebrew/bin/tmux /usr/local/bin/tmux 2>/dev/null | head -1)
  if [ -n "$TMUX_BIN" ]; then
    tm() { "$TMUX_BIN" -L "mcp-trust-$$" "$@"; }
    screen() { tm capture-pane -p -t trust -S - 2>/dev/null; }
    # The person's own terminal: this build's shim, then the real Codex, in a 160x45 pane that
    # stays for a look once Codex ends.
    tm new-session -d -x 160 -y 45 -s trust -c "$N" \
      "env ${shim_env[*]} PATH='$base_path' TERM=xterm-256color CMUX_TUI_MCP_RESOLVE_TRACE=1 '$CMUX' agent codex-wrapper"
    tm set-option -t trust remain-on-exit on >/dev/null
    for _ in $(seq 1 60); do screen | grep -qE "Trust and continue|Yes, continue" && break; perl -e 'select(undef,undef,undef,0.5)'; done
    screen > "$D/trust.dialog"
    prompt=$(grep -cE "Trust and continue|Yes, continue" "$D/trust.dialog")
    tm send-keys -t trust Enter
    # Codex either loads the folder's config and runs on, or refuses it and ends.
    for _ in $(seq 1 30); do
      screen | grep -qE "not supported for stdio|Error loading" && break
      [ "$(tm display -p -t trust '#{pane_dead}')" = 1 ] && break
      perl -e 'select(undef,undef,undef,0.5)'
    done
    perl -e 'select(undef,undef,undef,3)'
    screen > "$D/trust.screen"
    ended=$(tm display -p -t trust '#{pane_dead}')
    tm send-keys -t trust C-c; tm send-keys -t trust C-c
    for _ in $(seq 1 20); do [ "$(tm display -p -t trust '#{pane_dead}')" = 1 ] && break; perl -e 'select(undef,undef,undef,0.5)'; done
    screen > "$D/trust.after"
    # The pane's process group is Codex and the package processes it started: end that group, which this check
    # started, rather than every process whose command line names a path.
    trust_pg=$(tm display -p -t trust '#{pane_pid}')
    tm kill-server
    [ -n "$trust_pg" ] && kill -- -"$trust_pg" 2>/dev/null
    refused=$(grep -cE "not supported for stdio|Error loading" "$D/trust.screen")
    trusted=$(grep -c "\"$N\"" "$CODEX_HOME/config.toml" 2>/dev/null)
    entry=$(sed -n 's/.*cmux-tui: codex mcp get cmux: [0-9]* ms (\([A-Za-z]*\).*/\1/p' "$D/trust.after" | head -1)
    [ "${prompt:-0}" -ge 1 ] && [ "$ended" = 0 ] && [ "$refused" = 0 ] && [ "${trusted:-0}" -ge 1 ] \
      && grep -q "for shortcuts" "$D/trust.screen" && [ "$entry" = Doubt ]
    rc=$?; check "doubt [trust prompt]: a new folder with an HTTP project cmux entry, trusted at Codex's prompt (prompt shown: ${prompt:-0}, saved: ${trusted:-0}): answer ${entry:-?}, Codex runs on (ended: $ended, refused: $refused)" $rc
  else
    check "doubt [trust prompt]: tmux is missing" 1
  fi
  # 17 and 18 record the shim's launch (the fake `codex` asks the real one), then run the real
  # Codex with what the shim gave (none of the hooks, whose socket here answers nothing) and the
  # person's own arguments.
  fake_codex > "$D/bin/codex"; chmod +x "$D/bin/codex"
  replay_with() { # FOLDER ARGS...: the recorded launch's -c settings, with ARGS, as a real session
    local at=$1 recorded=() a v; shift
    while IFS= read -r a; do [ "$a" = -c ] && { IFS= read -r v; case "$v" in hooks*) ;; *) recorded+=(-c "$v") ;; esac; }; done < "$D/codex-args"
    session "$at" "$@" ${recorded[@]+"${recorded[@]}"}
  }
  # 17. `exec --trust` in a new folder with the same project file.
  T17=$D/doubt/trust; mkdir -p "$T17/.codex"; git -C "$T17" init -q; http_entry > "$T17/.codex/config.toml"
  : > "$CODEX_HOME/config.toml"
  if "$CODEX" exec --help 2>/dev/null | grep -q -- '--trust'; then
    record "$T17" exec --trust "say hi"
    given=$(grep -c '^mcp_servers\.' "$D/codex-args")
    result=$(replay_with "$T17" --trust)
    [ "$given" = 0 ] && [ ! -s "$D/shim.err" ] && [ "$result" = "|0|1" ]
    rc=$?; check "doubt [exec --trust]: no MCP setting ($given), nothing said, Codex trusts the folder and starts with its HTTP entry ($result)" $rc
  else
    echo "SKIP doubt [exec --trust]: this Codex has no --trust"
  fi
  # 18. `exec -C <link>`: the trust key is the link's path; the entry is HTTP.
  R18=$D/doubt/real; mkdir -p "$R18/.codex"; git -C "$R18" init -q; http_entry > "$R18/.codex/config.toml"
  ln -s "$R18" "$D/doubt/link"
  printf '[projects."%s"]\ntrust_level = "trusted"\n' "$D/doubt/link" > "$CODEX_HOME/config.toml"
  record "$D" exec -C "$D/doubt/link" "say hi"
  given=$(grep -c '^mcp_servers\.' "$D/codex-args")
  result=$(replay_with "$D" -C "$D/doubt/link")
  [ "$given" = 0 ] && [ ! -s "$D/shim.err" ] && [ "$result" = "|0|1" ]
  rc=$?; check "doubt [exec -C <link>]: no MCP setting ($given), nothing said, Codex starts with the link's HTTP entry ($result)" $rc
  : > "$CODEX_HOME/config.toml"
  # 19. Launches whose loaded config can differ from the question: nothing recorded, nothing said.
  sent=""
  for launch in "resume --last" "fork --last" "exec resume --last" "--worktree" "exec --trust hi" "--ignore-user-config exec hi" "--remote ws://127.0.0.1:9" "mcp list"; do
    # shellcheck disable=SC2086
    record "$P/sub" $launch
    if grep -q '^mcp_servers\.' "$D/codex-args" 2>/dev/null || [ -s "$D/shim.err" ]; then sent+=" [$launch]"; fi
  done
  [ -z "$sent" ]
  rc=$?; check "doubt [resume, fork, --worktree, --trust, --ignore-user-config, --remote, other subcommands]: no setting, nothing said${sent:+ (sent:$sent)}" $rc
  # 20. A resolver that does not answer in time: nothing, and the launch waits at most the limit.
  printf '#!/bin/sh\ncase " $* " in *" mcp get cmux --json "*) exec sleep 31;; esac\nfor a in "$@"; do printf "%%s\\n" "$a"; done > %s\n' \
    "$(sq "$D/codex-args")" > "$D/bin/codex"
  started=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  record "$P/sub" exec "say hi"
  took=$(( $(perl -MTime::HiRes=time -e 'printf "%d", time*1000') - started ))
  ! grep -q '^mcp_servers\.' "$D/codex-args" && grep -q '^hooks' "$D/codex-args" && [ ! -s "$D/shim.err" ] && [ "$took" -lt 4000 ] \
    && ! pgrep -f "sleep 31" >/dev/null
  rc=$?; check "doubt [resolver timed out]: no server, the hooks go, nothing said, launch took $took ms, the resolver's process is gone" $rc
  # 21. A user stdio entry, and an untrusted project file that defines cmux too: nothing.
  fake_codex > "$D/bin/codex"; chmod +x "$D/bin/codex"
  U21=$D/doubt/untrusted; mkdir -p "$U21/.codex"; git -C "$U21" init -q; http_entry > "$U21/.codex/config.toml"
  marker_entry u21-user > "$CODEX_HOME/config.toml"
  record "$U21" exec "say hi"
  rm -f "$D/bin/codex"
  ! grep -q '^mcp_servers\.' "$D/codex-args" && [ ! -s "$D/shim.err" ]
  rc=$?; check "doubt [untrusted HTTP project entry beside a user stdio entry]: no setting, nothing said" $rc
  : > "$CODEX_HOME/config.toml"; rm -f "$CODEX_HOME/auth.json"

  # 7. cmux setup mcp, with the real agents installed: a report, no write.
  printf '[mcp_servers.other]\ncommand = "/bin/true"\n' > "$CODEX_HOME/config.toml"
  before=$(cat "$CODEX_HOME/config.toml" "$CLAUDE_CONFIG_DIR/.claude.json" 2>/dev/null | shasum)
  report=$(env CMUX_NEXT_CONFIG_FILE="$settings" PATH="$base_path" "$CMUX" --json setup mcp 2>/dev/null)
  after=$(cat "$CODEX_HOME/config.toml" "$CLAUDE_CONFIG_DIR/.claude.json" 2>/dev/null | shasum)
  echo "$report" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["state"] == "ok" and r["undo"] is None, r
assert [c["state"] for c in r["clients"]] == ["terminals", "terminals"], r["clients"]
cmds = r["manual"]["commands"]
assert cmds[0].startswith("claude mcp add --scope user cmux -- ") and cmds[1].startswith("codex mcp add cmux -- "), cmds
assert "never runs them" in r["manual"]["text"], r["manual"]'
  ok=$?
  env CMUX_NEXT_CONFIG_FILE="$settings" PATH="$base_path" "$CMUX" --json setup mcp --remove >/dev/null 2>&1
  removed=$?
  [ $ok = 0 ] && [ "$before" = "$after" ] && [ $removed = 2 ] && [ ! -e "$HOME/.claude.json" ]
  check "cmux setup mcp: both agents get cmux in cmux, the manual lines are named, nothing is written, --remove is refused" $?
fi
echo "scratch: $D"
exit $failed
