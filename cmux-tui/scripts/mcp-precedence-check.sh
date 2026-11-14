#!/usr/bin/env bash
# Which `cmux` MCP server an agent uses when the person's own config has one
# named `cmux` and the cmux shim passes one too (agent_computer_use.rs).
#
#   mcp-precedence-check.sh [--cmux PATH]
#
# Needs `node`, `claude` and `codex` on PATH; no sign-in (Claude Code runs
# against a dead API endpoint: its MCP servers start before the first request).
# Every config lives in a scratch folder (HOME, CLAUDE_CONFIG_DIR, CODEX_HOME):
# this account's own ~/.claude.json and ~/.codex are never read or written.
# Run it on a fleet Mac or a VM, never on a person's laptop.
#
# Without --cmux it checks the agents' own rules with two fake servers, `user`
# (the config entry) and `shim` (what the shim passes):
#   1. Claude Code: a --mcp-config server replaces a same-named user-scope
#      entry whole (only `shim` starts).
#   2. Codex: -c mcp_servers.cmux.* merges into the config.toml entry key by
#      key (the entry's cwd, timeouts and other env keys stay).
#   3. Codex: a server under its own name with the entry turned off
#      (-c mcp_servers.cmux.enabled=false) gets none of the entry's settings.
# With --cmux PATH (a cmux build's bundled CLI) it also runs that build's real
# `claude` and `codex` shims and checks what each agent gets.
# Prints PASS or FAIL per check and exits 1 on any FAIL.
set -u
CMUX=""
[ "${1:-}" = --cmux ] && CMUX=$2
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d /tmp/mcp-precedence.XXXXXX)
NODE=$(command -v node) || { echo "node is not on PATH"; exit 2; }
CLAUDE=$(command -v claude) || { echo "claude is not on PATH"; exit 2; }
CODEX=$(command -v codex) || { echo "codex is not on PATH"; exit 2; }
failed=0
check() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; failed=1; fi; }
timeout() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
mkdir -p "$D/home" "$D/claude" "$D/codex" "$D/work" "$D/bin"
export HOME=$D/home CLAUDE_CONFIG_DIR=$D/claude CODEX_HOME=$D/codex
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
json_srv() { printf '{"type":"stdio","command":"%s","args":["%s","%s","%s"]}' "$NODE" "$F" "$1" "$2"; }
claude_session() { # a -p session against a dead endpoint; its MCP servers start first
  ANTHROPIC_API_KEY=sk-dummy ANTHROPIC_BASE_URL=http://127.0.0.1:9 timeout 90 \
    "$@" -p "say hi" --debug-file "$D/claude.debug" >/dev/null 2>&1
}
user_toml() { # the person's Codex entry, with settings beyond command and args
  cat > "$CODEX_HOME/config.toml" <<TOML
[mcp_servers.cmux]
command = "$1"
args = ["mcp", "serve"]
cwd = "/user-cwd"
startup_timeout_sec = 7
[mcp_servers.cmux.env]
USER_ONLY = "from-config"
TOML
}
echo "claude $("$CLAUDE" --version)"
echo "codex $("$CODEX" --version)"

# 1. Claude Code
L=$D/claude.log; : > "$L"
printf '{"mcpServers":{"cmux":%s}}' "$(json_srv user "$L")" > "$CLAUDE_CONFIG_DIR/.claude.json"
claude_session "$CLAUDE" --mcp-config "$(printf '{"mcpServers":{"cmux":%s}}' "$(json_srv shim "$L")")"
grep -qx "started shim" "$L" && ! grep -qx "started user" "$L"
check "claude: --mcp-config's cmux replaces the user-scope cmux ($(tr '\n' ' ' < "$L"))" $?

# 2. Codex: same name merges
user_toml /opt/other/cmux
merged=$("$CODEX" -c "mcp_servers.cmux.command=\"$NODE\"" -c 'mcp_servers.cmux.args=["shim"]' \
  -c 'mcp_servers.cmux.env={A="1"}' mcp list --json 2>&1)
echo "$merged" | tr -d ' \n' | grep -q '"cwd":"/user-cwd"' && echo "$merged" | grep -q USER_ONLY
check "codex: -c mcp_servers.cmux.* keeps the config entry's cwd and env keys" $?

# 3. Codex: own name, entry off
separate=$("$CODEX" -c 'mcp_servers.cmux.enabled=false' -c "mcp_servers.cmux_terminal.command=\"$NODE\"" \
  -c 'mcp_servers.cmux_terminal.args=["shim"]' mcp list --json 2>&1)
echo "$separate" | python3 -c '
import json, sys
servers = {s["name"]: s for s in json.load(sys.stdin)}
own, user = servers["cmux_terminal"], servers["cmux"]
assert own["enabled"] and own["transport"]["cwd"] is None and not own["transport"]["env"], own
assert not user["enabled"], user
'
check "codex: cmux_terminal gets none of the entry's settings; the entry is off" $?

if [ -n "$CMUX" ]; then
  # 4. The build's real shims. A listening socket stands in for the daemon's.
  sock=$D/d.sock
  "$NODE" -e 'require("net").createServer(()=>{}).listen(process.argv[1])' "$sock" &
  listener=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$sock" ] && break; perl -e 'select(undef,undef,undef,0.2)'; done
  settings=$D/home/.config/cmux/cmux-next-dev.json
  mkdir -p "$(dirname "$settings")"; echo '{"agents": {"cmuxMcp": "on"}}' > "$settings"
  shim_env=(CMUX_TUI_SOCKET="$sock" CMUX_TUI_TERMINAL_ID=term_1 CMUX_NEXT_CONFIG_FILE="$settings"
            PATH="$(dirname "$CLAUDE"):$(dirname "$CODEX"):$(dirname "$NODE"):/usr/bin:/bin")
  : > "$L"
  printf '{"mcpServers":{"cmux":%s}}' "$(json_srv user "$L")" > "$CLAUDE_CONFIG_DIR/.claude.json"
  ANTHROPIC_API_KEY=sk-dummy ANTHROPIC_BASE_URL=http://127.0.0.1:9 env "${shim_env[@]}" \
    timeout 90 "$CMUX" agent claude-wrapper -p "say hi" --debug-file "$D/shim.debug" >/dev/null 2>&1
  grep -q 'MCP server "cmux".*serverVersion":{"name":"cmux"' "$D/shim.debug" && ! grep -qx "started user" "$L"
  check "claude shim: the agent's cmux is this build's server, not the user-scope entry" $?
  # Codex: what the shim passes, read back through the real codex.
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > %s\n' "$D/codex-args" > "$D/bin/codex"
  chmod +x "$D/bin/codex"
  user_toml "$CMUX"
  env "${shim_env[@]}" PATH="$D/bin:/usr/bin:/bin" "$CMUX" agent codex-wrapper >/dev/null 2>&1
  overrides=(); while IFS= read -r a; do [ "$a" = -c ] && { read -r v; overrides+=(-c "$v"); }; done < "$D/codex-args"
  "$CODEX" "${overrides[@]}" mcp list --json 2>&1 | python3 -c '
import json, sys
servers = {s["name"]: s for s in json.load(sys.stdin)}
own = servers.get("cmux_terminal")
assert own and own["enabled"] and own["transport"]["cwd"] is None, servers
assert "USER_ONLY" not in (own["transport"]["env"] or {}), own
assert own["transport"]["command"] == sys.argv[1], own
assert not servers["cmux"]["enabled"], servers["cmux"]
' "$CMUX"
  check "codex shim: the agent's cmux server is this build's, with none of the entry's settings" $?
  kill "$listener" 2>/dev/null
fi
echo "scratch: $D"
exit $failed
