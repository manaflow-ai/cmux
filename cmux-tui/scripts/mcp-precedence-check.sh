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
#   5. Codex: the shim's off switch (the reported command and args with
#      enabled=false) starts a session without "invalid transport" and keeps
#      the cmux server from starting, whether the session has that entry from
#      the user layer, a project layer or a plugin, or has none (a new
#      worktree, --ignore-user-config); a bare enabled=false fails there.
#      A session runs `codex exec` against a dead endpoint: its MCP servers
#      start first, which the fake server logs.
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
print(value)' "$field" 2>/dev/null # no answer (Codex refused its config): empty
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

# 5. The off switch
dead=(-c 'model_provider="dead"' -c 'model_providers.dead={name="dead",base_url="http://127.0.0.1:9/v1",env_key="DEAD_KEY",wire_api="responses",request_max_retries=0,stream_max_retries=0}')
switch=(-c "mcp_servers.cmux.command=\"$NODE\"" -c "mcp_servers.cmux.args=[\"$F\",\"X\",\"$L\"]" -c 'mcp_servers.cmux.enabled=false')
session() { # FOLDER ARGS...: start a session, then what started ("started <label> ..." or empty) and whether Codex refused its config
  local at=$1; shift; : > "$L"
  (cd "$at" && DEAD_KEY=x CODEX_API_KEY=sk-test timeout 12 "$CODEX" exec --skip-git-repo-check "${dead[@]}" "$@" hi \
     < /dev/null > "$D/session.out" 2>&1)
  printf '%s|%s' "$(tr '\n' ' ' < "$L")" "$(grep -c 'invalid transport' "$D/session.out")"
}
off_case() { # NAME FOLDER LABEL ARGS...: alone the LABEL server starts; with the switch none does, no crash
  local name=$1 at=$2 label=$3; shift 3
  local alone with
  alone=$(session "$at" "$@"); with=$(session "$at" "$@" "${switch[@]}")
  { [ -z "$label" ] || [ "$alone" = "started $label |0" ]; } && [ "$with" = "|0" ]
  check "codex off switch [$name]: alone '${alone%|*}', with the switch '${with%|*}', no invalid transport" $?
}
cmux_entry() { printf '[mcp_servers.cmux]\ncommand = "%s"\nargs = ["%s", "%s", "%s"]\n' "$NODE" "$F" "$1" "$L"; }
cmux_entry user > "$CODEX_HOME/config.toml"
off_case "user layer" "$D/work" user
{ printf '[projects."%s"]\ntrust_level = "trusted"\n' "$P"; } > "$CODEX_HOME/config.toml"
mkdir -p "$P/.codex"; cmux_entry project > "$P/.codex/config.toml"
off_case "project layer" "$P/sub" project
rm -rf "$P/.codex"
printf '[features]\nplugins = true\nremote_plugin = false\n[plugins."cmuxp@openai-api-curated"]\nenabled = true\n' > "$CODEX_HOME/config.toml"
PR=$CODEX_HOME/plugins/cache/openai-api-curated/cmuxp/local; mkdir -p "$PR/.codex-plugin"
printf '{"name":"cmuxp","version":"local"}' > "$PR/.codex-plugin/plugin.json"
printf '{"mcpServers":{"cmux":{"type":"stdio","command":"%s","args":["%s","plugin","%s"]}}}' "$NODE" "$F" "$L" > "$PR/.mcp.json"
off_case "plugin" "$D/work" plugin
rm -rf "$CODEX_HOME/plugins"
: > "$CODEX_HOME/config.toml"
off_case "no entry" "$D/work" ""
cmux_entry user > "$CODEX_HOME/config.toml"
off_case "--ignore-user-config, entry only in the user layer" "$D/work" "" --ignore-user-config
bare=$(session "$D/work" -c 'mcp_servers.cmux.enabled=false' --ignore-user-config)
[ "${bare#*|}" != 0 ]
check "codex: a bare enabled=false where the session has no cmux entry fails with invalid transport" $?

if [ -n "$CMUX" ]; then
  # 4. The build's real shims. A listening socket stands in for the daemon's.
  sock=$D/d.sock
  "$NODE" -e 'require("net").createServer(()=>{}).listen(process.argv[1])' "$sock" &
  listener=$!
  # The listener ends with the script, however it ends.
  trap 'kill "$listener" 2>/dev/null' EXIT
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
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = mcp ] && exec %q "$@"; done\nfor a in "$@"; do printf "%%s\\n" "$a"; done > %q\n' \
    "$CODEX" "$D/codex-args" > "$D/bin/codex"
  chmod +x "$D/bin/codex"
  # The shim's PATH: the fake codex first, then node (an npm-installed Codex
  # is a node script) and the system tools.
  shim_path="$D/bin:$(dirname "$NODE"):/usr/bin:/bin"
  user_plain() { printf '[mcp_servers.cmux]\ncommand = "%s"\nargs = ["mcp", "serve"]\n' "$CMUX" > "$CODEX_HOME/config.toml"; }
  # shim_case NAME FOLDER LOADED VERIFY_ARGS -- SHIM_ARGS: run the shim in
  # FOLDER with SHIM_ARGS; Codex itself (mcp get in the effective folder with
  # VERIFY_ARGS) must report a layer's cwd when LOADED=yes, none when no. The
  # shim's server is always cmux_terminal; it turns the person's cmux entry
  # off whenever Codex reports it (another cmux's, on), never when Codex has
  # no answer.
  shim_case() {
    local name=$1 at=$2 loaded=$3; shift 3
    # Empty arrays are expanded as ${a[@]+"${a[@]}"}: macOS's bash 3.2 calls
    # "${a[@]}" of an empty array unbound under set -u.
    local verify=() shim=() effective=$at
    while [ $# -gt 0 ] && [ "$1" != -- ]; do verify+=("$1"); shift; done; shift
    shim=(${1+"$@"})
    for ((k = 0; k < ${#shim[@]}; k++)); do
      if [ "${shim[$k]}" = -C ]; then
        case "${shim[$((k + 1))]}" in /*) effective=${shim[$((k + 1))]} ;; *) effective=$at/${shim[$((k + 1))]} ;; esac
      fi
    done
    rm -f "$D/codex-args"
    (cd "$at" && env "${shim_env[@]}" PATH="$shim_path" "$CMUX" agent codex-wrapper ${shim[@]+"${shim[@]}"} >/dev/null 2>&1)
    local reported; reported=$(codex_get "$effective" transport.cwd ${verify[@]+"${verify[@]}"})
    python3 - "$D/codex-args" "$loaded" "$reported" <<'PY'
import sys
args = open(sys.argv[1]).read().split("\n")
loaded, reported = sys.argv[2] == "yes", sys.argv[3]
settings = [args[i + 1] for i, a in enumerate(args[:-1]) if a == "-c"]
names = {s.split(".")[1] for s in settings if s.startswith("mcp_servers.") and ".command=" in s}
off = "mcp_servers.cmux.enabled=false" in settings
# The off switch carries the reported transport: cmux's command and args.
if off:
    assert {"mcp_servers.cmux.command", "mcp_servers.cmux.args"} <= {s.split("=")[0] for s in settings}, settings
    names.discard("cmux")
if reported == "":
    # Codex refused its config (no answer): nothing is turned off.
    want = ({"cmux_terminal"}, False)
else:
    assert (reported != "None") == loaded, f"Codex reported cwd={reported}, expected loaded={loaded}"
    want = ({"cmux_terminal"}, True)
assert (names, off) == want, f"shim placed {names} off={off}, want {want}"
PY
    local rc=$?
    local said=${reported:-no answer: $(cd "$effective" && "$CODEX" ${verify[@]+"${verify[@]}"} mcp get cmux --json 2>&1 >/dev/null | grep -v '^$' | tail -1 | cut -c1-90)}
    check "codex shim [$name]: Codex reports the layer ($said); the shim turns cmux off by that answer" $rc
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
  # Launches Codex's answer does not describe: the shim turns nothing off.
  # Turning the entry off there could fail Codex: --worktree starts in a new
  # untrusted worktree where a project-only cmux entry is not loaded.
  no_turn_off() { # NAME FOLDER SHIM_ARGS...: the shim adds cmux_terminal, turns nothing off
    local name=$1 at=$2; shift 2
    rm -f "$D/codex-args"
    (cd "$at" && env "${shim_env[@]}" PATH="$shim_path" "$CMUX" agent codex-wrapper "$@" >/dev/null 2>&1)
    grep -q '^mcp_servers.cmux_terminal.command=' "$D/codex-args" && ! grep -q '^mcp_servers.cmux.enabled=false$' "$D/codex-args"
    check "codex shim [$name]: cmux_terminal added, nothing turned off" $?
  }
  rm -f "$CODEX_HOME/work.config.toml"
  # A project-only cmux entry: in the trusted repo Codex reports it; the
  # --worktree session would not load it.
  mkdir -p "$P/.codex"
  printf '[mcp_servers.cmux]\ncommand = "%s"\nargs = ["mcp", "serve"]\ncwd = "/project-cwd"\n' "$CMUX" > "$P/.codex/config.toml"
  printf 'model = "x"\n[projects."%s"]\ntrust_level = "trusted"\n' "$P" > "$CODEX_HOME/config.toml"
  [ "$(codex_get "$sub" transport.cwd)" = /project-cwd ]
  check "codex: the trusted repo's project layer has a cmux entry (the worktree case's premise)" $?
  no_turn_off "--worktree" "$sub" --worktree
  no_turn_off "exec --worktree" "$sub" exec --worktree hi
  no_turn_off "resume --last" "$sub" resume --last
  no_turn_off "exec resume --last" "$sub" exec resume --last
  no_turn_off "fork --last" "$sub" fork --last
  no_turn_off "exec hi --worktree" "$sub" exec hi --worktree
  no_turn_off "exec hi --ignore-user-config" "$sub" exec hi --ignore-user-config
  # The switch the shim sends where Codex reports the entry carries its
  # transport: from a folder where that entry is not loaded it is still valid.
  rm -f "$D/codex-args"
  (cd "$sub" && env "${shim_env[@]}" PATH="$shim_path" "$CMUX" agent codex-wrapper >/dev/null 2>&1)
  overrides=(); while IFS= read -r a; do [ "$a" = -c ] && { read -r v; overrides+=(-c "$v"); }; done < "$D/codex-args"
  grep -q '^mcp_servers.cmux.command=' "$D/codex-args" && grep -q '^mcp_servers.cmux.args=' "$D/codex-args" \
    && grep -q '^mcp_servers.cmux.enabled=false$' "$D/codex-args" \
    && (cd "$D/work" && "$CODEX" "${overrides[@]}" mcp list --json 2>/dev/null) | python3 -c '
import json, sys
servers = {s["name"]: s for s in json.load(sys.stdin)}
assert servers["cmux"]["enabled"] is False and servers["cmux_terminal"]["enabled"], servers'
  check "codex shim: its off switch carries the reported command and args, valid where the entry is not loaded" $?
  # And the crash the turn-off would cause where the entry is not loaded:
  # enabled=false for a cmux Codex has no transport for.
  (cd "$D/work" && "$CODEX" -c 'mcp_servers.cmux.enabled=false' mcp list --json 2>&1 >/dev/null) | grep -q "invalid transport"
  check "codex: enabled=false on a cmux entry the session does not load fails with invalid transport" $?
  rm -rf "$P/.codex"; user_plain

  # The merged result: the agent's own server carries no layer's settings.
  printf '[projects."%s"]\ntrust_level = "trusted"\n' "$P" >> "$CODEX_HOME/config.toml"
  mkdir -p "$P/.codex"; printf '[mcp_servers.cmux]\ncwd = "/project-cwd"\n' > "$P/.codex/config.toml"
  (cd "$sub" && env "${shim_env[@]}" PATH="$shim_path" "$CMUX" agent codex-wrapper >/dev/null 2>&1)
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
fi
echo "scratch: $D"
exit $failed
