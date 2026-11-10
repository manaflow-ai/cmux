#!/bin/bash
# run-agent.sh ARM MODEL EFFORT TIMEOUT PROMPT_FILE OUT_DIR
#
# Runs inside the macOS guest. Starts `codex exec` once in the console user's
# Aqua session (launchd gui/<uid>), so Computer Use servers see the GUI
# session's WindowServer and LaunchServices rather than the SSH bootstrap
# namespace, and waits for it. Both arms run the same agent, model, effort and
# prompt; only the computer-use tools differ:
#   codex-cu  Codex's bundled Computer Use plugin
#   cmux-cu   cmux's `cmux computer-use mcp`, with Codex's plugin turned off
# Shell, patching and web search are off for both, so a task can be done only
# through computer use (no AppleScript or sqlite shortcuts).
set -euo pipefail
arm=$1 model=$2 effort=$3 timeout_s=$4 prompt_file=$5 out=$6
mkdir -p "$out"
uid=$(id -u)
label=dev.cmux.cubench.agent
plist=$out/agent.plist
codex=${CUBENCH_CODEX:-$HOME/.local/bin/codex}
cmux=${CUBENCH_CMUX:-/Applications/$(cat "$HOME/cub-assets/cmux-app-name" 2>/dev/null)/Contents/Resources/bin/cmux}

common=(exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox
  -m "$model" -c "model_reasoning_effort=\"$effort\""
  --disable shell_tool --disable unified_exec
  -c 'include_apply_patch_tool=false' -c 'web_search="disabled"' -C "$out")
case $arm in
  codex-cu)
    # Codex hosts Codex Computer Use's MCP client itself (the service checks
    # that its caller is signed by OpenAI), the way Codex's own config sets it.
    sky="$HOME/.codex/computer-use/Codex Computer Use.app"
    args=("${common[@]}"
      -c 'mcp_servers.computer-use.enabled=true'
      -c "mcp_servers.computer-use.command=\"$sky/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient\""
      -c 'mcp_servers.computer-use.args=["mcp"]'
      -c "mcp_servers.computer-use.cwd=\"$HOME/.codex/computer-use\""
      -c "mcp_servers.computer-use.env.SKY_CUA_SERVICE_PATH=\"$sky\""
      -c "mcp_servers.computer-use.env.CODEX_CLI_PATH=\"$codex\""
      -c "mcp_servers.computer-use.env.CODEX_HOME=\"$HOME/.codex\""
      -c 'mcp_servers.computer-use.startup_timeout_sec=60'
      -c 'mcp_servers.computer-use.tool_timeout_sec=120') ;;
  cmux-cu)
    args=("${common[@]}" --disable computer_use
      -c 'plugins."computer-use@openai-bundled".enabled=false'
      -c 'plugins."unified-computer-use@openai-bundled".enabled=false'
      -c "mcp_servers.cmux_computer_use.command=\"$cmux\""
      -c 'mcp_servers.cmux_computer_use.args=["computer-use","mcp"]'
      -c "mcp_servers.cmux_computer_use.env.CMUX_TUI_SOCKET=\"$(getconf DARWIN_USER_TEMP_DIR)cmux-tui-$(id -u)/cmux-app-$(cat "$HOME/cub-assets/cmux-tag" 2>/dev/null || echo cuparity2).sock\""
      -c 'mcp_servers.cmux_computer_use.tool_timeout_sec=120') ;;
  *) echo "unknown arm $arm" >&2; exit 2 ;;
esac

/usr/bin/python3 - "$plist" "$label" "$out" "$codex" "$prompt_file" "${args[@]}" <<'PY'
import plistlib, shlex, sys
plist, label, out, codex, prompt_file, *args = sys.argv[1:]
cmd = " ".join(shlex.quote(a) for a in [codex, *args, "-"])
wrapped = f'cd {shlex.quote(out)}; {cmd} < {shlex.quote(prompt_file)} > events.jsonl 2> stderr.txt; echo $? > rc'
plistlib.dump({"Label": label, "ProgramArguments": ["/bin/bash", "-c", wrapped],
               "RunAtLoad": True, "ProcessType": "Interactive",
               "EnvironmentVariables": {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
                                        "HOME": __import__("os").path.expanduser("~")}},
              open(plist, "wb"))
PY
launchctl bootout "gui/$uid/$label" 2>/dev/null || true
rm -f "$out/rc"
start=$(date +%s)
launchctl bootstrap "gui/$uid" "$plist"
# Wait on the job's own result file, bounded by the task timeout.
while [[ ! -f $out/rc ]]; do
  if (( $(date +%s) - start > timeout_s )); then
    echo timeout > "$out/rc"; break
  fi
  /bin/sleep 1
done
launchctl bootout "gui/$uid/$label" 2>/dev/null || true
echo "$(( $(date +%s) - start ))" > "$out/seconds"
cat "$out/rc"
