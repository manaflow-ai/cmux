#!/usr/bin/env bash
# Quit-persistence acceptance test (plans/cmux-next/quit-persistence.md 5.2).
#
# Runs ON a fleet Mac with a GUI session (cmux-lawrence-2) against a tagged
# DEBUG cmux-next build, for example:
#   cmux-ci build cmux --ref <sha> --tag hq48qp-v2 ...; cmux-ci artifact <id> app.zip
#   scp app.zip scripts/fleet-quit-persistence.sh cmux-lawrence-2:qp/
#   ssh cmux-lawrence-2 'bash qp/fleet-quit-persistence.sh --zip qp/app.zip --tag hq48qp-v2'
#
# It drives the app only through its own sockets (debug.quit, action.run,
# debug.window_snapshot, the bundled cmux and acpmux CLIs), records the PID
# of every process it starts and never sends a signal: apps quit through
# debug.quit, acpmux stops with `acpmux daemon shutdown` in the tag home.
# It leaves no process behind. Exit 0 when every check passes or fails as
# expected; 1 when a check fails that is not on the expected-fail list.
#
# EXPECTED FAILURES (remove a line when its fix lands; an XPASS is reported):
#   second-quit-keeps          dialogs lead + app lifecycle (D2, plan Q3): a second Cmd-Q is ignored today
#   dock-quit-inactive         dialogs lead + app lifecycle (G7, plan Q3): no inactive-app quit hook (debug.quit inactive)
#   update-relaunch-no-prompt  app lifecycle (D3, plan Q3): no debug hook drives a Sparkle relaunch
# The End Everything checks (end-everything-*) are NOT on this list: they
# must pass (the home_not_closable fix).
set -euo pipefail

XFAIL=(second-quit-keeps dock-quit-inactive update-relaunch-no-prompt)

app="" zip="" tag="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --zip) zip="$2"; shift 2 ;;
    --tag) tag="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    -h|--help) sed -n 2,22p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$tag" ] || { echo "--tag is required" >&2; exit 2; }
out="${out:-$HOME/qp/$tag/run-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$out"

# 1. Install and launch -------------------------------------------------------
if [ -n "$zip" ]; then
  dest="$HOME/qp/$tag/app"
  rm -rf "$dest" && mkdir -p "$dest"
  ditto -x -k "$zip" "$dest"
  app="$(ls -d "$dest"/*.app | head -1)"
fi
[ -d "$app" ] || { echo "no app: pass --app or --zip" >&2; exit 2; }
slug="$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
SOCK="/tmp/cmux-debug-$slug.sock"
BIN="$app/Contents/Resources/bin"
export ACPMUX_HOME="$HOME/.acpmux/tags/$slug"
export ACPMUX_SOCKET="$ACPMUX_HOME/acpmux.sock"
pass=0 fail=0 xfail=0 xpass=0
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$out/run.log"; }
is_xfail() { local n; for n in "${XFAIL[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1; }
# check NAME OK(0/1) DETAIL
check() {
  local name="$1" ok="$2" detail="${3:-}"
  if is_xfail "$name"; then
    if [ "$ok" = 0 ]; then xpass=$((xpass+1)); log "XPASS $name $detail (remove it from XFAIL)"
    else xfail=$((xfail+1)); log "XFAIL $name $detail"; fi
  elif [ "$ok" = 0 ]; then pass=$((pass+1)); log "PASS  $name $detail"
  else fail=$((fail+1)); log "FAIL  $name $detail"; fi
}
cond() { if "$@"; then echo 0; else echo 1; fi; }
rpc() { python3 - "$SOCK" "$@" <<'PY'
import json, socket, sys
path, method = sys.argv[1], sys.argv[2]
params = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
s = socket.socket(socket.AF_UNIX); s.settimeout(float(sys.argv[4]) if len(sys.argv) > 4 else 30)
s.connect(path)
s.sendall((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
buf = b""
while not buf.endswith(b"\n"):
    c = s.recv(1 << 20)
    if not c: break
    buf += c
print(buf.decode().strip())
PY
}
# rpc_ok METHOD PARAMS: retries a main-actor timeout (state not_run) once.
rpc_ok() { local r; r="$(rpc "$@" 2>/dev/null || true)"; case "$r" in *'"not_run"'*) sleep 1; r="$(rpc "$@" 2>/dev/null || true)" ;; esac; printf '%s' "$r"; }
jq_py() { python3 -c "import json,sys; d=json.loads(sys.stdin.read() or 'null'); print(eval(sys.argv[1]))" "$1"; }
alive() { ps -p "$1" >/dev/null 2>&1; }
app_pid() { pgrep -f "^$app/Contents/MacOS/" | head -1 || true; }
wait_socket() { local i; for i in $(seq 1 60); do rpc debug.windows '{}' 3 2>/dev/null | grep -q '"ok": *true' && return 0; sleep 1; done; return 1; }
wait_exit() { local i; for i in $(seq 1 "$2"); do alive "$1" || return 0; sleep 1; done; return 1; }
launch() { open -g -n "$app"; wait_socket; sleep 4; APP_PID="$(app_pid)"; log "app pid $APP_PID"; }
daemon_sock() { ps -o command= -p "$TUI_PID" | sed -E 's/.*--socket ([^ ]+).*/\1/'; }
cli() { "$BIN/cmux" --socket "$DSOCK" "$@"; }
acp() { "$BIN/acpmux" "$@"; }
snapshot() { rpc_ok debug.window_snapshot "{\"path\":\"$out/$1.png\"}" >/dev/null || true; }

# quit_with BUTTON...: debug.quit {open} then press each button in turn.
quit_with() {
  local r; r="$(rpc_ok debug.quit '{"open":true}')"; sleep 3
  for b in "$@"; do rpc_ok debug.quit "{\"press\":\"$b\"}" >/dev/null || true; sleep 2; done
}

log "app $app tag $tag out $out"
launch
check app-launch "$(cond test -n "$APP_PID")" "socket $SOCK"
TUI_PID="$(pgrep -f "^$BIN/cmux-tui --headless --session cmux-app-$slug " | head -1 || true)"
ACP_PID="$(pgrep -f "^$BIN/acpmux daemon run" | while read -r p; do ps -E -o command= -p "$p" | grep -q "ACPMUX_HOME=$ACPMUX_HOME " && echo "$p"; done | head -1 || true)"
log "cmux-tui pid $TUI_PID acpmux pid $ACP_PID"
for p in "$TUI_PID" "$ACP_PID"; do
  read -r ppid pgid <<<"$(ps -o ppid=,pgid= -p "$p" 2>/dev/null || echo "x x")"
  check "daemon-detached-$p" "$(cond test "$ppid" = 1 -a "$pgid" = "$p")" "ppid=$ppid pgid=$pgid"
done
DSOCK="$(daemon_sock)"

# 2. Terminals and a second workspace -----------------------------------------
TA="$(cli workspace create --name qp-a --json | jq_py 'd["value"]["terminal_id"]')"
cli workspace create --name qp-b --json >/dev/null
cli terminal "$TA" write --text "echo QP-MARKER; for i in \$(seq 1 200); do echo pre-\$i; done; echo \$\$ > $out/shell.pid; sh -c 'echo \$\$ > $out/loop.pid; i=0; while true; do i=\$((i+1)); echo tick-\$i; sleep 1; done'
" >/dev/null
sleep 4
SHELL_PID="$(cat "$out/shell.pid")" LOOP_PID="$(cat "$out/loop.pid")"
HOSTS="$(pgrep -f "^$BIN/cmux-tui __terminal-host" | tr '\n' ' ' || true)"
log "terminal $TA shell $SHELL_PID loop $LOOP_PID hosts $HOSTS"

# 3. An agent in a turn, and an agent tab ---------------------------------------
acp new -d -m claude -n qp-agent --cwd "$out" --policy approve-all --stall 0 \
  "Run exactly this with the Bash tool, timeout 600000 ms, and wait: for i in \$(seq 1 400); do echo agent-tick-\$i; sleep 1; done. Then say DONE." \
  >"$out/agent-new.log" 2>&1 &
AGENT_CLI_PID=$!
for i in $(seq 1 60); do acp session tail qp-agent 2>/dev/null | grep -q tool_progress && break; sleep 2; done
SESSION="$(acp ls --json | jq_py '[s["sessionId"] for s in d["sessions"] if s["name"]=="qp-agent"][0]')"
agent_running() { acp ls 2>/dev/null | grep qp-agent | grep -q running; }
check agent-in-turn "$(cond agent_running)" "session $SESSION"
rpc_ok action.run '{"id":"palette.newAgentChat"}' >/dev/null; sleep 5
rpc_ok debug.agent_pane "{\"action\":\"select_session\",\"session\":\"$SESSION\"}" >"$out/agent-select.json"

# 4. Before ---------------------------------------------------------------------
cli workspace list --json >"$out/pre-ws.json"
cli terminal list --json >"$out/pre-term.json"
rpc_ok debug.windows '{}' >"$out/pre-windows.json"
snapshot pre

# 5. Cmd-Q (keep) -----------------------------------------------------------------
rpc_ok debug.quit '{"open":true}' >/dev/null; sleep 3
rpc_ok debug.quit '{}' >"$out/prompt.json"
snapshot prompt
check prompt-shown "$(cond grep -q '"asking": *true' "$out/prompt.json")"
check prompt-default-keep "$(cond grep -q '"default": *"keep"' "$out/prompt.json")"
# The app was launched with open -g: it is not active, so its window is not key.
check prompt-attached-window-not-key "$(cond grep -q '"attached": *true' "$out/prompt.json")"
# The agent in its turn is counted (the Home Chief never is).
check prompt-counts-agents "$(cond python3 -c "
import json,sys
d=json.load(open('$out/prompt.json')); p=(d.get('result') or d)['prompt']
sys.exit(0 if (p.get('agents') or 0)>=1 and p.get('agents_in_turn',0)>=1 and p.get('busy_agents') else 1)")" "$(tr -d '\n' <"$out/prompt.json" | cut -c1-300)"
dialog="$(rpc_ok debug.dialog '{}' || true)"
printf '%s\n' "$dialog" >"$out/prompt-dialog.json"
check prompt-is-cmux-dialog "$(cond grep -q '"identifier": *"cmux.dialog.quit"' <<<"$dialog")"
check prompt-reports-activated "$(cond grep -q '"activated"' "$out/prompt.json")"
rpc_ok debug.quit '{"press":"quit"}' >/dev/null || true
check app-quits-on-keep "$(cond wait_exit "$APP_PID" 15)"

# 6. Survive the reap grace -----------------------------------------------------
sleep 40
for p in "$TUI_PID" "$ACP_PID" "$SHELL_PID" "$LOOP_PID"; do check "keep-survives-$p" "$(cond alive "$p")"; done

# 7. Relaunch -------------------------------------------------------------------
launch
cli workspace list --json >"$out/post-ws.json"
cli terminal list --json >"$out/post-term.json"
cli terminal "$TA" history read >"$out/post-hist.txt" 2>&1 || true
rpc_ok debug.windows '{}' >"$out/post-windows.json"
same_ids() { python3 - "$out/pre-$1.json" "$out/post-$1.json" <<'PY'
import json,sys
a,b=(sorted(x["id"] for x in json.load(open(p))) for p in sys.argv[1:3]); sys.exit(0 if a==b else 1)
PY
}
check relaunch-same-workspace-ids "$(cond same_ids ws)"
check relaunch-same-terminal-ids "$(cond same_ids term)"
check relaunch-same-window "$(cond python3 -c "
import json,sys
w=lambda p:[x['id'] for x in json.load(open(p))['result']['windows']]
sys.exit(0 if w('$out/pre-windows.json')==w('$out/post-windows.json') else 1)")"
check relaunch-scrollback-marker "$(cond grep -q QP-MARKER "$out/post-hist.txt")"
check relaunch-command-ran-without-gap "$(cond python3 -c "
import re,sys
n=sorted(set(int(x) for x in re.findall(r'tick-(\d+)',open('$out/post-hist.txt').read())))
sys.exit(0 if n and n==list(range(n[0],n[-1]+1)) and n[-1]>60 else 1)")"
agent_same() { acp ls --json | grep -q "$SESSION" && agent_running; }
check relaunch-agent-session-same-and-running "$(cond agent_same)"
rpc_ok debug.agent_pane '{"action":"chat_state"}' >"$out/post-agent.json"
check agent-tab-restored "$(cond grep -q "$SESSION" "$out/post-agent.json")"
snapshot post
rpc_ok action.run '{"id":"selectWorkspaceByNumber","args":{"index":1}}' >/dev/null; sleep 2
snapshot post-terminal

# 9. Variants (on the live app) ---------------------------------------------------
rpc_ok debug.quit '{"open":true}' >/dev/null; sleep 3
rpc_ok debug.quit '{"open":true}' >/dev/null; sleep 4
if alive "$APP_PID"; then
  check second-quit-keeps 1 "the second request was ignored"
  rpc_ok debug.quit '{"press":"cancel"}' >/dev/null || true; sleep 2
else
  check second-quit-keeps "$(cond alive "$TUI_PID")" "app quit; daemon alive"
  launch
fi
check dock-quit-inactive 1 "needs debug.quit {open:true, inactive:true}"
check update-relaunch-no-prompt 1 "needs a debug hook for updaterWillRelaunchApplication"

# 8b. Quit Everything, keep layout (D1: End Sessions, Keep Layout today) -------------
HOSTS="$(pgrep -f "^$BIN/cmux-tui __terminal-host" | tr '\n' ' ' || true)"
quit_with end end-keep-layout
check quit-everything-app-quits "$(cond wait_exit "$APP_PID" 70)"
for p in $HOSTS "$SHELL_PID" "$LOOP_PID" "$TUI_PID"; do check "quit-everything-ends-$p" "$(cond wait_exit "$p" 20)"; done
# Every End choice ends the agents (acpmux _acpmux/shutdown endAgents) before
# the terminals: the acpmux daemon exits and the turn is settled as cancelled.
check quit-ends-agents "$(cond wait_exit "$ACP_PID" 20)" "acpmux $ACP_PID"
launch
check quit-ends-agents-turn-cancelled "$(cond python3 -c "
import json,subprocess,sys
d=json.loads(subprocess.run(['$BIN/acpmux','ls','--json'],capture_output=True,text=True).stdout)
s=[x for x in d['sessions'] if x['name']=='qp-agent']
sys.exit(0 if s and s[0]['status'] not in ('running','waiting') else 1)")"
TUI_PID="$(pgrep -f "^$BIN/cmux-tui --headless --session cmux-app-$slug " | head -1 || true)"
DSOCK="$(daemon_sock)"
sleep 3
cli workspace list --json >"$out/kept-ws.json"
check quit-everything-keeps-layout "$(cond python3 -c "
import json,sys
a=sorted(x['id'] for x in json.load(open('$out/pre-ws.json'))); b=sorted(x['id'] for x in json.load(open('$out/kept-ws.json')))
sys.exit(0 if a==b else 1)")"

# 8a. End Everything (must pass: home_not_closable fix) -------------------------------
cli terminal list --json >"$out/ee-term.json"
HOSTS="$(pgrep -f "^$BIN/cmux-tui __terminal-host" | tr '\n' ' ' || true)"
log "End Everything: cmux-tui $TUI_PID hosts $HOSTS"
rpc_ok debug.quit '{"open":true}' >/dev/null; sleep 3
rpc_ok debug.quit '{"press":"end"}' >/dev/null; sleep 2
rpc_ok debug.quit '{"press":"end-everything"}' >/dev/null || true
sleep 3
failure="$(rpc_ok debug.quit '{}' || true)"
if printf '%s' "$failure" | grep -q '"failure"'; then
  printf '%s\n' "$failure" >"$out/end-everything-failure.json"
  check end-everything-no-failure 1 "$(printf '%s' "$failure" | tr -d '\n' | cut -c1-300)"
  fdialog="$(rpc_ok debug.dialog '{}' || true)"
  check end-everything-failure-is-cmux-dialog "$(cond grep -q '"identifier": *"cmux.dialog.quitFailure"' <<<"$fdialog")"
  rpc_ok debug.quit '{"press":"quit-anyway"}' >/dev/null || true
else
  check end-everything-no-failure 0
fi
check end-everything-app-quits "$(cond wait_exit "$APP_PID" 70)"
check end-everything-stops-daemon "$(cond wait_exit "$TUI_PID" 20)"
for p in $HOSTS; do check "end-everything-ends-host-$p" "$(cond wait_exit "$p" 20)"; done
launch
TUI_PID="$(pgrep -f "^$BIN/cmux-tui --headless --session cmux-app-$slug " | head -1 || true)"
DSOCK="$(daemon_sock)"
cli workspace list --json >"$out/ee-ws.json"
check end-everything-leaves-home-only "$(cond python3 -c "
import json,sys
w=json.load(open('$out/ee-ws.json')); sys.exit(0 if [x.get('extra',{}).get('kind') for x in w]==['home'] else 1)")"

# 10. Cleanup through the apps' own paths ---------------------------------------------
# Home only has no terminal, so an interactive quit would not ask: quit with
# an explicit End Sessions instead (the CLI's `app quit --end-sessions`).
rpc_ok action.run '{"id":"quit","args":{"endSessions":true}}' >/dev/null || true
wait_exit "$APP_PID" 70 || log "app $APP_PID still running"
acp session cancel qp-agent >/dev/null 2>&1 || true
acp daemon shutdown >/dev/null 2>&1 || true
sleep 3
left=""
for p in "$APP_PID" "$TUI_PID" "$ACP_PID" "$SHELL_PID" "$LOOP_PID" "$AGENT_CLI_PID"; do alive "$p" && left="$left $p"; done
check cleanup-no-process-left "$(cond test -z "$left")" "$left"

log "RESULT pass=$pass fail=$fail xfail=$xfail xpass=$xpass out=$out"
[ "$fail" = 0 ]
