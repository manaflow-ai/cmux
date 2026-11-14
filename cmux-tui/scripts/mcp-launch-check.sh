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
#   6. agents.cmuxMcp off or unanswered: neither shim passes a server;
#   7. cmux setup mcp with the real claude and codex installed writes nothing
#      to their configs, names the manual lines, and refuses --remove.
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
timeout() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
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
check "claude: --mcp-config's cmux replaces the user-scope cmux ($(tr '\n' ' ' < "$L"))" $?
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
  base_path="$(dirname "$CLAUDE"):$(dirname "$CODEX"):$(dirname "$NODE"):/usr/bin:/bin"

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
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > %s\n' "$(sq "$D/codex-args")" > "$D/bin/codex.tmp"
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

  # 6. Off and unanswered: neither shim passes a server.
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > %s\n' "$(sq "$D/claude-args")" > "$D/bin/claude"
  chmod +x "$D/bin/claude"
  for value in off ask; do
    answer "$value"
    record "$P/sub" exec "say hi"
    rm -f "$D/claude-args"
    (cd "$P/sub" && env "${shim_env[@]}" PATH="$shim_path" "$CMUX" agent claude-wrapper -p hi >/dev/null 2>&1)
    ! grep -q '^mcp_servers\.' "$D/codex-args" && ! grep -qx -- '--mcp-config' "$D/claude-args"
    check "agents.cmuxMcp $value: neither shim passes a cmux server" $?
  done
  rm -f "$D/bin/claude" "$D/bin/codex"
  answer on

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
