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
#   1. Claude Code: a --mcp-config server replaces a same-named entry of the
#      user, project (.mcp.json) and local scopes whole (only `shim` starts).
#   2. Codex: -c mcp_servers.cmux.* merges into the config.toml entry key by
#      key (the entry's cwd, timeouts and other env keys stay).
#   3. Codex: a server under its own name with the entry turned off
#      (-c mcp_servers.cmux.enabled=false) gets none of the entry's settings.
#   4. Codex: which layers merge into mcp_servers.cmux: a trusted project's
#      .codex/config.toml (root to launch folder; not when untrusted, not above
#      the git root) and $CODEX_HOME/NAME.config.toml with --profile NAME.
# With --cmux PATH (a cmux build's bundled CLI) it also runs that build's real
# `claude` and `codex` shims (the codex one from a trusted project with a
# .codex layer, and with --profile) and checks what each agent gets.
# JSON is read from stdout only: Codex may warn on stderr.
# Prints PASS or FAIL per check and exits 1 on any FAIL.
set -u
CMUX=""
[ "${1:-}" = --cmux ] && CMUX=$2
# A new scratch folder under the temporary folder, by its real path (/tmp is
# /private/tmp on macOS; project paths are matched as Codex resolves them).
# Everything below writes only there: refuse anything else.
T=$(cd "${TMPDIR:-/tmp}" && pwd -P) || exit 2
D=$(mktemp -d "$T/mcp-precedence.XXXXXX") || exit 2
D=$(cd "$D" && pwd -P) || exit 2
case "$D" in "$T"/mcp-precedence.?*) ;; *) echo "refusing scratch folder $D"; exit 2 ;; esac
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

# 2. Codex: same name merges
user_toml /opt/other/cmux
merged=$("$CODEX" -c "mcp_servers.cmux.command=\"$NODE\"" -c 'mcp_servers.cmux.args=["shim"]' \
  -c 'mcp_servers.cmux.env={A="1"}' mcp list --json 2>/dev/null)
echo "$merged" | tr -d ' \n' | grep -q '"cwd":"/user-cwd"' && echo "$merged" | grep -q USER_ONLY
check "codex: -c mcp_servers.cmux.* keeps the config entry's cwd and env keys" $?

# 3. Codex: own name, entry off
separate=$("$CODEX" -c 'mcp_servers.cmux.enabled=false' -c "mcp_servers.cmux_terminal.command=\"$NODE\"" \
  -c 'mcp_servers.cmux_terminal.args=["shim"]' mcp list --json 2>/dev/null)
echo "$separate" | python3 -c '
import json, sys
servers = {s["name"]: s for s in json.load(sys.stdin)}
own, user = servers["cmux_terminal"], servers["cmux"]
assert own["enabled"] and own["transport"]["cwd"] is None and not own["transport"]["env"], own
assert not user["enabled"], user
'
check "codex: cmux_terminal gets none of the entry's settings; the entry is off" $?

# 4. Codex layers (what Codex itself reports, `codex mcp get cmux --json`)
codex_get() { # field $2 of the cmux entry Codex reports for a launch in $1 (args after)
  local at=$1 field=$2; shift 2
  (cd "$at" && "$CODEX" "$@" mcp get cmux --json 2>/dev/null) | python3 -c '
import json, sys
entry = json.load(sys.stdin)
value = entry
for part in sys.argv[1].split("."):
    value = value.get(part) if isinstance(value, dict) else None
print(value)' "$field"
}
P=$D/proj; mkdir -p "$P/sub" "$P/.codex" "$D/.codex"; git -C "$P" init -q
printf '[mcp_servers.cmux]\ncwd = "/project-cwd"\n' > "$P/.codex/config.toml"
# Above the project root, under another key: it must stay out.
printf '[mcp_servers.cmux]\nstartup_timeout_sec = 99\n' > "$D/.codex/config.toml"
printf '[mcp_servers.cmux]\ncwd = "/profile-cwd"\n' > "$CODEX_HOME/work.config.toml"
printf '[mcp_servers.cmux]\ncommand = "/opt/cmux"\nargs = ["mcp", "serve"]\n' > "$CODEX_HOME/config.toml"
untrusted=$(codex_get "$P/sub" transport.cwd)
printf '[projects."%s"]\ntrust_level = "trusted"\n[projects."%s"]\ntrust_level = "trusted"\n' "$P" "$D" >> "$CODEX_HOME/config.toml"
trusted=$(codex_get "$P/sub" transport.cwd); above=$(codex_get "$P/sub" startup_timeout_sec)
profile=$(codex_get "$D/work" transport.cwd --profile work)
[ "$untrusted" = None ] && [ "$trusted" = /project-cwd ] && [ "$above" = None ] && [ "$profile" = /profile-cwd ]
check "codex: a trusted project's layer merges, not above its root; --profile's file merges (untrusted=$untrusted trusted=$trusted above=$above profile=$profile)" $?
rm -rf "$D/.codex" "$CODEX_HOME/work.config.toml"
for i in 1 2 3 4 5 6 7 8 9 10; do
  s=$(perl -MTime::HiRes=time -e 'printf "%.6f", time'); (cd "$P/sub" && "$CODEX" mcp get cmux --json >/dev/null 2>&1)
  e=$(perl -MTime::HiRes=time -e 'printf "%.6f", time'); perl -e "printf '%d ', ($e-$s)*1000"
done | { read -r times; echo "codex mcp get latency (ms, 10 runs, trusted project): $times"; }

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
  # `timeout` is a function here: it runs `env`, never the other way round.
  ANTHROPIC_API_KEY=sk-dummy ANTHROPIC_BASE_URL=http://127.0.0.1:9 timeout 90 env "${shim_env[@]}" \
    "$CMUX" agent claude-wrapper -p "say hi" --debug-file "$D/shim.debug" >/dev/null 2>&1
  grep -q 'MCP server "cmux".*serverVersion":{"name":"cmux"' "$D/shim.debug" && ! grep -qx "started user" "$L"
  check "claude shim: the agent's cmux is this build's server, not the user-scope entry" $?
  # Codex: the shim asks Codex itself for the cmux entry (`mcp get`), then
  # places its server. A fake `codex` first on PATH records the launch's
  # arguments and hands `mcp get` to the real one.
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = mcp ] && exec %s "$@"; done\nfor a in "$@"; do printf "%%s\\n" "$a"; done > %s\n' \
    "$CODEX" "$D/codex-args" > "$D/bin/codex"
  chmod +x "$D/bin/codex"
  user_plain() { printf '[mcp_servers.cmux]\ncommand = "%s"\nargs = ["mcp", "serve"]\n' "$CMUX" > "$CODEX_HOME/config.toml"; }
  # shim_case NAME FOLDER LOADED VERIFY_ARGS -- SHIM_ARGS: run the shim in
  # FOLDER with SHIM_ARGS; Codex itself (mcp get in the effective folder with
  # VERIFY_ARGS) must report a layer's cwd when LOADED=yes, none when no; the
  # shim must then place its server as cmux_terminal with cmux off (loaded) or
  # as cmux (not); the agent's own server never gets the layer's cwd.
  shim_case() {
    local name=$1 at=$2 loaded=$3; shift 3
    local verify=() shim=() effective=$at
    while [ $# -gt 0 ] && [ "$1" != -- ]; do verify+=("$1"); shift; done; shift
    shim=("$@")
    for ((k = 0; k < ${#shim[@]}; k++)); do
      if [ "${shim[$k]}" = -C ]; then
        case "${shim[$((k + 1))]}" in /*) effective=${shim[$((k + 1))]} ;; *) effective=$at/${shim[$((k + 1))]} ;; esac
      fi
    done
    rm -f "$D/codex-args"
    (cd "$at" && env "${shim_env[@]}" PATH="$D/bin:/usr/bin:/bin" "$CMUX" agent codex-wrapper "${shim[@]}" >/dev/null 2>&1)
    local reported; reported=$(codex_get "$effective" transport.cwd "${verify[@]}")
    python3 - "$D/codex-args" "$loaded" "$reported" <<'PY'
import sys
args = open(sys.argv[1]).read().split("\n")
loaded, reported = sys.argv[2] == "yes", sys.argv[3]
settings = [args[i + 1] for i, a in enumerate(args[:-1]) if a == "-c"]
names = {s.split(".")[1] for s in settings if s.startswith("mcp_servers.") and ".command=" in s}
off = "mcp_servers.cmux.enabled=false" in settings
assert (reported != "None") == loaded, f"Codex reported cwd={reported}, expected loaded={loaded}"
want = ({"cmux_terminal"}, True) if loaded else ({"cmux"}, False)
assert (names, off) == want, f"shim placed {names} off={off}, want {want}"
PY
    check "codex shim [$name]: Codex reports the layer (${reported}); the shim places its server by that answer" $?
  }
  sub=$P/sub
  mkdir -p "$P/.codex"; printf '[mcp_servers.cmux]\ncwd = "/project-cwd"\n' > "$P/.codex/config.toml"
  user_plain
  shim_case "untrusted project" "$sub" no --
  printf '[projects."%s"]\ntrust_level = "trusted"\n' "$P" >> "$CODEX_HOME/config.toml"
  shim_case "trusted project" "$sub" yes --
  shim_case "-C into the trusted project" "$D/work" yes -- -C "$sub"
  # A worktree of the trusted repo, with its own .codex layer.
  git -C "$P" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$P" worktree add -q "$D/wt"; mkdir -p "$D/wt/.codex"
  printf '[mcp_servers.cmux]\ncwd = "/worktree-cwd"\n' > "$D/wt/.codex/config.toml"
  shim_case "worktree of the trusted repo" "$D/wt" yes --
  # Per-folder trust: only the launch folder is trusted, its layer there.
  rm -rf "$P/.codex"; mkdir -p "$sub/.codex"
  printf '[mcp_servers.cmux]\ncwd = "/sub-cwd"\n' > "$sub/.codex/config.toml"
  user_plain; printf '[projects."%s"]\ntrust_level = "trusted"\n' "$sub" >> "$CODEX_HOME/config.toml"
  shim_case "per-folder trust" "$sub" "$( [ "$(codex_get "$sub" transport.cwd)" = None ] && echo no || echo yes )" --
  rm -rf "$sub/.codex"
  # Profiles: --profile forms and a top-level `profile =`.
  user_plain; printf '[mcp_servers.cmux]\ncwd = "/profile-cwd"\n' > "$CODEX_HOME/work.config.toml"
  shim_case "no profile" "$D/work" no --
  shim_case "-pwork" "$D/work" yes --profile work -- -pwork
  shim_case "-p=work" "$D/work" yes --profile work -- -p=work
  shim_case "--profile=work" "$D/work" yes --profile work -- --profile=work
  { printf 'profile = "work"\n'; cat "$CODEX_HOME/config.toml"; } > "$CODEX_HOME/c.tmp" && mv "$CODEX_HOME/c.tmp" "$CODEX_HOME/config.toml"
  shim_case "top-level profile =" "$D/work" "$( [ "$(codex_get "$D/work" transport.cwd)" = None ] && echo no || echo yes )" --
  rm -f "$CODEX_HOME/work.config.toml"; user_plain
  # The merged result: the agent's own server carries no layer's settings.
  printf '[projects."%s"]\ntrust_level = "trusted"\n' "$P" >> "$CODEX_HOME/config.toml"
  mkdir -p "$P/.codex"; printf '[mcp_servers.cmux]\ncwd = "/project-cwd"\n' > "$P/.codex/config.toml"
  (cd "$sub" && env "${shim_env[@]}" PATH="$D/bin:/usr/bin:/bin" "$CMUX" agent codex-wrapper >/dev/null 2>&1)
  overrides=(); while IFS= read -r a; do [ "$a" = -c ] && { read -r v; overrides+=(-c "$v"); }; done < "$D/codex-args"
  (cd "$sub" && "$CODEX" "${overrides[@]}" mcp list --json 2>/dev/null) | python3 -c '
import json, os, sys
servers = {s["name"]: s for s in json.load(sys.stdin)}
own = servers.get("cmux_terminal")
assert own and own["enabled"] and own["transport"]["cwd"] is None, servers
assert os.path.realpath(own["transport"]["command"]) == os.path.realpath(sys.argv[1]), own
assert not servers["cmux"]["enabled"], servers["cmux"]
' "$CMUX"
  check "codex shim: the agent's cmux server is this build's, with none of the project layer's settings" $?
  kill "$listener" 2>/dev/null
fi
echo "scratch: $D"
exit $failed
