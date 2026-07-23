#!/bin/bash
# remote-tmux-fuzz-run.sh — outward oracles for the two remote-tmux bugs that no in-process
# test can see, because both are only observable from outside the app.
#
#   HEALTHY-DETACH (bug: detach-reverted). Closing one mirror must detach that mirror's control
#   client from the remote tmux and let the remote etterminal die with it. With
#   detachThenStop() the control-client count drops by one; with plain stop() it does not move,
#   the local et client dies anyway, and the remote half keeps the client forever.
#
#   DEAD-STREAM (bug: barrier-disabled). Against a stream cmux cannot publish a topology from,
#   the attach RPC must answer an error and leave no workspace behind. With the readiness
#   barrier removed the same attach answers ok and leaves workspaces wired to nothing.
#
# The oracles are counts taken on the host's own tmux server and process table, not anything
# the app reports about itself:
#
#   control clients   tmux list-clients, flags containing control-mode
#   remote half       etterminal processes
#   local half        et client processes
#   leftovers         workspaces that exist after a case and did not exist before it
#
# Three rules this script is built around, each learned by getting it wrong here:
#
#   Contamination fakes a pass. A stale control client from an earlier run makes "the count
#   dropped" arrive for free, and clients from an exited app were measured still attached 46
#   minutes later. So every case starts from a measured-zero baseline, reaps if it is not zero,
#   and reports INCONCLUSIVE rather than a verdict if the reap does not clear it.
#
#   An error is not evidence. "The RPC failed and no workspace appeared" is also what a typo'd
#   command, an unknown broker name or a dead etserver produces. DEAD-STREAM therefore only
#   passes if it also observed control clients arriving on the host's tmux during the attach —
#   proof the case reached the far end before failing.
#
#   The failure path leaks, and the leak does not clear itself. Each case reaps what it caused
#   through the hairpin and confirms the reap with a fresh count, so the next case cannot
#   inherit a dirty baseline.
#
# Usage:
#   scripts/remote-tmux-fuzz-run.sh [case ...]        # default: both cases
#   CMUX_TAG=etbroker scripts/remote-tmux-fuzz-run.sh HEALTHY-DETACH
#   FUZZ_BREAK_ORACLE=healthy-drop scripts/remote-tmux-fuzz-run.sh   # self-test: must FAIL
#   FUZZ_BREAK_ORACLE=dead-ok      scripts/remote-tmux-fuzz-run.sh   # self-test: must FAIL
#
# Exit status: 0 all cases passed, 1 some case FAILed, 2 no FAIL but some case INCONCLUSIVE.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${CMUX_TAG:-etbroker}"
HOST="${FUZZ_HOST:-cmux-ethost}"
HAIRPIN="${FUZZ_HAIRPIN:-cmux-srvA}"
TMUX_BIN="${FUZZ_TMUX_BIN:-/opt/homebrew/bin/tmux}"
# The "remote" host is this machine over loopback, so the tmux cmux mirrors is the default
# server. Address it by socket path rather than bare `tmux` so nothing here can start or kill a
# server by accident: list-clients/list-sessions on a missing socket just fail.
TMUX_SOCKET="${FUZZ_TMUX_SOCKET:-/private/tmp/tmux-$(id -u)/default}"
HEALTHY_BROKER="${FUZZ_HEALTHY_BROKER:-local}"
DEAD_BROKER="${FUZZ_DEAD_BROKER:-pipe}"
DEAD_BROKER_EXEC="${FUZZ_DEAD_BROKER_EXEC:-$HOME/.cmux/et-pipebroker}"
CMUX_JSON="${FUZZ_CMUX_JSON:-$HOME/.config/cmux/cmux.json}"
APP_BUNDLE="${FUZZ_APP_BUNDLE:-$HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG}/Build/Products/Debug/cmux DEV ${TAG}.app}"
DEAD_ERROR_NEEDLE="${FUZZ_DEAD_ERROR_NEEDLE:-could not mirror any tmux session}"
EXPECT_DROP="${FUZZ_EXPECT_DROP:-1}"
BREAK_ORACLE="${FUZZ_BREAK_ORACLE:-}"

# DEBUG timer overrides, passed in the app's launch environment. They only shorten waits that
# exist because the peer stopped answering; nothing here depends on their values being small.
BARRIER_SECONDS="${FUZZ_BARRIER_SECONDS:-2}"
BACKSTOP_SECONDS="${FUZZ_BACKSTOP_SECONDS:-1}"
RECONNECT_BASE_SECONDS="${FUZZ_RECONNECT_BASE_SECONDS:-1}"
RECONNECT_MAX_SECONDS="${FUZZ_RECONNECT_MAX_SECONDS:-2}"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
WORK_DIR="${FUZZ_WORK_DIR:-/tmp/cmux-fuzz-run-$RUN_ID}"
mkdir -p "$WORK_DIR"
LOG_FILE="$WORK_DIR/run.log"

case "$BREAK_ORACLE" in
  ""|healthy-drop|dead-ok) ;;
  *) echo "FUZZ_BREAK_ORACLE must be empty, healthy-drop, or dead-ok" >&2; exit 64 ;;
esac
if [ "$BREAK_ORACLE" = "healthy-drop" ]; then
  # Demand two control clients disappear when a single mirror closes. The fixed code drops
  # exactly one, so this arm is a deliberate FAIL that proves the oracle can fail at all.
  EXPECT_DROP=2
fi

log() { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }

now() { python3 -c 'import time; print("%.2f" % time.time())'; }
since() { python3 -c "import sys; print('%.1f' % (float(sys.argv[1]) - float(sys.argv[2])))" "$(now)" "$1"; }

shquote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Signals from this shell are swallowed by the sandbox (kill returns 0 and the process lives),
# and `open` here cannot reach the WindowServer. Both have to go through the loopback hairpin,
# which runs outside the sandbox. Exit codes come back unreliably, so every remote command
# ends by echoing what it observed and the caller reads that.
hp() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$HAIRPIN" "zsh -lc $(shquote "$1")" 2>&1
}

tmx() { "$TMUX_BIN" -S "$TMUX_SOCKET" "$@" 2>/dev/null; }

count_control() { tmx list-clients -F '#{client_flags}' | grep -c 'control-mode' || true; }
count_plain_clients() { tmx list-clients -F '#{client_flags}' | grep -vc 'control-mode' || true; }
count_control_for_session() { tmx list-clients -F '#{client_session} #{client_flags}' | awk -v s="$1" '$1==s && $2 ~ /control-mode/' | wc -l | tr -d ' '; }
control_ttys() { tmx list-clients -F '#{client_tty} #{client_flags}' | awk '$2 ~ /control-mode/ {print $1}'; }
list_sessions() { tmx list-sessions -F '#{session_name}' | sort; }
count_etterminal() { pgrep -x etterminal | wc -l | tr -d ' '; }
count_etclient() { ps -Ao command= | awk '$1=="/usr/local/bin/et"' | wc -l | tr -d ' '; }
# The bracket in the pattern is not cosmetic. pkill/pgrep -f match every process's whole command
# line, including the ssh client and the remote shell that are carrying the pattern itself, so a
# plain pattern kills the very connection running it (measured: ssh died with 144 and the rest of
# the reap never ran). Writing one character as a class keeps the pattern from matching its own
# argv while still matching the target.
APP_PATTERN="cmux DEV ${TAG}[.]app/Contents/MacOS"
app_pids() { pgrep -f "$APP_PATTERN" || true; }

cli() { CMUX_TAG="$TAG" "$REPO_ROOT/scripts/cmux-debug-cli.sh" "$@"; }

# Wait on an observed edge, with a bounded backstop. Never a sleep as the primary wait.
wait_edge() {
  local desc="$1" timeout_s="$2"; shift 2
  local deadline=$(( $(date +%s) + timeout_s ))
  while :; do
    if "$@"; then return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "    wait timed out after ${timeout_s}s: $desc"
      return 1
    fi
    sleep 0.2
  done
}

# ---------------------------------------------------------------- cmux.json (the user's file)

CONFIG_BACKUP=""
CONFIG_TOUCHED=0

restore_config() {
  if [ "$CONFIG_TOUCHED" = 1 ] && [ -n "$CONFIG_BACKUP" ] && [ -f "$CONFIG_BACKUP" ]; then
    cp "$CONFIG_BACKUP" "$CMUX_JSON"
    if cmp -s "$CONFIG_BACKUP" "$CMUX_JSON"; then
      log "cmux.json restored from $CONFIG_BACKUP (byte-identical); brokers now: $(declared_brokers)"
    else
      log "cmux.json RESTORE MISMATCH — backup kept at $CONFIG_BACKUP"
    fi
    CONFIG_TOUCHED=0
  fi
}
declared_brokers() {
  python3 -c 'import json,sys
try: cfg = json.load(open(sys.argv[1]))
except Exception: raise SystemExit(0)
print(",".join(((cfg.get("remoteTmux") or {}).get("brokers") or {}).keys()))' "$CMUX_JSON" 2>/dev/null
}
# Restore on every exit path, including a failure or an interrupt: the file belongs to the user.
trap 'rc=$?; touch "$WORK_DIR/stop-sampler" 2>/dev/null; restore_config; exit $rc' EXIT
trap 'exit 130' INT TERM

# Sets CONFIG_BACKUP, CONFIG_TOUCHED and REG_STATUS in this shell. Never call it inside a
# command substitution: that runs in a subshell, the backup bookkeeping is lost with it, and the
# exit trap then leaves the user's cmux.json carrying this script's broker entry (measured).
REG_STATUS=""
ensure_dead_broker_registered() {
  REG_STATUS=""
  if [ ! -f "$CMUX_JSON" ]; then
    REG_STATUS="missing $CMUX_JSON"
    return 1
  fi
  CONFIG_BACKUP="$CMUX_JSON.fuzzbak.$RUN_ID"
  if ! cp "$CMUX_JSON" "$CONFIG_BACKUP"; then
    REG_STATUS="could not back up $CMUX_JSON"
    return 1
  fi
  CONFIG_TOUCHED=1
  REG_STATUS="$(python3 - "$CMUX_JSON" "$DEAD_BROKER" "$DEAD_BROKER_EXEC" <<'PY'
import json, sys
path, name, executable = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    cfg = json.load(fh)
brokers = cfg.setdefault("remoteTmux", {}).setdefault("brokers", {})
if name in brokers:
    print("already-declared")
else:
    brokers[name] = {"executable": executable, "arguments": ["-et", "-fallback"]}
    with open(path, "w") as fh:
        json.dump(cfg, fh, indent=2)
        fh.write("\n")
    print("added")
PY
  )"
}

# ------------------------------------------------------------------------------- app lifecycle

kill_app() {
  hp "pkill -f '$APP_PATTERN'; true" >/dev/null
  wait_edge "tagged app exits" 20 test_no_app
}
test_no_app() { [ -z "$(app_pids)" ]; }

launch_app() {
  local before_pids
  before_pids="$(app_pids | tr '\n' ' ')"
  local open_out
  open_out="$(hp "open -n --env CMUX_REMOTE_TMUX_TOPOLOGY_BARRIER_SECONDS=$BARRIER_SECONDS --env CMUX_REMOTE_TMUX_DETACH_BACKSTOP_SECONDS=$BACKSTOP_SECONDS --env CMUX_REMOTE_TMUX_RECONNECT_BASE_SECONDS=$RECONNECT_BASE_SECONDS --env CMUX_REMOTE_TMUX_RECONNECT_MAX_SECONDS=$RECONNECT_MAX_SECONDS $(shquote "$APP_BUNDLE"); echo OPENRC=\$?")"
  log "    launch: $(printf '%s' "$open_out" | tr '\n' ' ')"
  case "$open_out" in
    *OPENRC=0*) ;;
    *) log "    open failed"; return 1 ;;
  esac
  # Two edges, both required: a pid that was not there before (so a dying instance cannot pass
  # for the new one) and an RPC that answers on the tagged socket.
  wait_edge "new app pid" 40 app_pid_is_new "$before_pids" || return 1
  wait_edge "debug socket answers ping" 40 ping_ok || return 1
  APP_PID="$(app_pids | head -1)"
  log "    app pid=$APP_PID barrier=${BARRIER_SECONDS}s backstop=${BACKSTOP_SECONDS}s reconnect=${RECONNECT_BASE_SECONDS}/${RECONNECT_MAX_SECONDS}s"
  return 0
}
app_pid_is_new() {
  local before="$1" pid
  for pid in $(app_pids); do
    case " $before " in *" $pid "*) ;; *) return 0 ;; esac
  done
  return 1
}
ping_ok() { cli ping >/dev/null 2>&1; }

# ------------------------------------------------------------------------------- baseline/reap

reap() {
  local label="$1"
  local ctl0 ett0 et0
  ctl0="$(count_control)"; ett0="$(count_etterminal)"; et0="$(count_etclient)"
  log "  reap ($label): before control=$ctl0 etterminal=$ett0 et=$et0"
  # Order matters: kill the app first. While a mirror is still open, killing its etterminal
  # only makes cmux reattach and spawn a fresh one (measured).
  kill_app || log "    app did not exit"
  # Safe because the baseline gate proved there were no etterminal/et processes before the
  # case, so everything alive now was caused by it.
  hp "pkill -x etterminal; pkill -f '/usr/local/bin/et[ ]-p'; pkill -f 'et-[l]ocalbroker'; pkill -f 'et-[p]ipebroker'; true" >/dev/null
  wait_edge "etterminal and et clients exit" 20 procs_clear
  # Backstop for a control client whose remote half is already gone: detach that client by its
  # own tty. Never `detach-client -s <session>`, which would evict the human's client too.
  if [ "$(count_control)" != "0" ]; then
    local tty
    for tty in $(control_ttys); do
      log "    detach-client -t $tty (stale control client)"
      tmx detach-client -t "$tty" || true
    done
    wait_edge "stale control clients detach" 10 no_control
  fi
  local ctl1 ett1 et1
  ctl1="$(count_control)"; ett1="$(count_etterminal)"; et1="$(count_etclient)"
  log "  reap ($label): after  control=$ctl1 etterminal=$ett1 et=$et1  (reaped control=$((ctl0-ctl1)) etterminal=$((ett0-ett1)) et=$((et0-et1)))"
  REAP_EVIDENCE="control ${ctl0}->${ctl1}, etterminal ${ett0}->${ett1}, et ${et0}->${et1}"
  [ "$ctl1" = "0" ] && [ "$ett1" = "0" ] && [ "$et1" = "0" ]
}
procs_clear() { [ "$(count_etterminal)" = "0" ] && [ "$(count_etclient)" = "0" ]; }
no_control() { [ "$(count_control)" = "0" ]; }

# Returns 0 clean, 1 dirty after a reap attempt (caller reports INCONCLUSIVE).
require_clean_baseline() {
  local ctl ett et
  ctl="$(count_control)"; ett="$(count_etterminal)"; et="$(count_etclient)"
  log "  baseline: control=$ctl etterminal=$ett et=$et"
  if [ "$ctl" = "0" ] && [ "$ett" = "0" ] && [ "$et" = "0" ]; then
    BASELINE_EVIDENCE="control=0 etterminal=0 et=0"
    return 0
  fi
  log "  baseline dirty — reaping before grading"
  reap "dirty baseline" || true
  ctl="$(count_control)"; ett="$(count_etterminal)"; et="$(count_etclient)"
  BASELINE_EVIDENCE="control=$ctl etterminal=$ett et=$et after reap"
  if [ "$ctl" = "0" ] && [ "$ett" = "0" ] && [ "$et" = "0" ]; then
    log "  baseline clean after reap"
    return 0
  fi
  log "  baseline STILL dirty: control=$ctl etterminal=$ett et=$et"
  return 1
}

# ------------------------------------------------------------------------------- app inventory

# One line per workspace, "<id>\t<title>", across every window, so a workspace parked in
# another window still counts as a leftover.
snapshot_workspaces() {
  local win
  for win in $(cli --json list-windows 2>/dev/null | python3 -c 'import json,sys
try: print("\n".join(w["id"] for w in json.load(sys.stdin)))
except Exception: pass'); do
    cli --json workspace list --window "$win" 2>/dev/null | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: raise SystemExit(0)
for w in d.get("workspaces", []):
    print("%s\t%s" % (w["id"], w.get("custom_title") or ""))'
  done | sort
}

# ------------------------------------------------------------------- results table bookkeeping

RESULT_FILE="$WORK_DIR/results.tsv"
: > "$RESULT_FILE"
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESULT_FILE"; }

# ============================================================== case 1: HEALTHY-DETACH (bug A)

case_healthy_detach() {
  local name="HEALTHY-DETACH"
  log ""
  log "=== $name (broker=$HEALTHY_BROKER) — closing one mirror must detach its control client"
  if ! require_clean_baseline; then
    record "$name" INCONCLUSIVE "baseline not clean: $BASELINE_EVIDENCE"
    return 0
  fi
  local sessions_before
  sessions_before="$(list_sessions)"
  local session_count
  session_count="$(printf '%s\n' "$sessions_before" | grep -c . || true)"
  log "  host tmux sessions: $session_count ($(printf '%s' "$sessions_before" | tr '\n' ' '))"
  if [ "$session_count" -lt 2 ]; then
    record "$name" INCONCLUSIVE "host tmux has $session_count sessions; need >=2 so one mirror can close while others stay"
    return 0
  fi
  if ! launch_app; then
    record "$name" INCONCLUSIVE "tagged app did not come up"
    return 0
  fi

  local t0 attach_json rc
  t0="$(now)"
  attach_json="$(cli --json ssh-tmux "$HOST" --transport et --broker "$HEALTHY_BROKER" 2>&1)"
  rc=$?
  local elapsed; elapsed="$(since "$t0")"
  printf '%s\n' "$attach_json" > "$WORK_DIR/healthy-attach.json"
  log "  attach rc=$rc elapsed=${elapsed}s"
  local ids
  ids="$(printf '%s' "$attach_json" | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: raise SystemExit(0)
if d.get("mirrored") is True:
    print("\n".join(d.get("workspace_ids") or []))')"
  local id_count; id_count="$(printf '%s\n' "$ids" | grep -c . || true)"
  if [ "$id_count" -lt 2 ]; then
    log "  attach reply: $(printf '%s' "$attach_json" | tr '\n' ' ' | cut -c1-200)"
    record "$name" INCONCLUSIVE "attach did not mirror >=2 sessions (workspace_ids=$id_count, rc=$rc)"
    reap "$name" || true
    return 0
  fi

  # Edge: the control clients cmux just created show up on the host's tmux.
  wait_edge "control clients reach $id_count" 30 control_at_least "$id_count" || true
  local ctl_before ett_before et_before plain_before
  ctl_before="$(count_control)"; ett_before="$(count_etterminal)"; et_before="$(count_etclient)"; plain_before="$(count_plain_clients)"
  log "  after attach: mirrors=$id_count control=$ctl_before etterminal=$ett_before et=$et_before (non-control clients=$plain_before)"
  if [ "$ctl_before" -lt 2 ]; then
    record "$name" INCONCLUSIVE "only $ctl_before control clients attached; the case never reached the host's tmux"
    reap "$name" || true
    return 0
  fi

  # Pick one mirror and learn which session it holds, so the oracle can name the client that
  # must go away rather than just watching a total.
  local target_id target_session
  target_id="$(printf '%s\n' "$ids" | tail -1)"
  target_session="$(snapshot_workspaces | awk -F'\t' -v id="$target_id" '$1==id {print $2}')"
  if [ -z "$target_session" ]; then
    record "$name" INCONCLUSIVE "could not resolve the session behind workspace $target_id"
    reap "$name" || true
    return 0
  fi
  local target_clients_before
  target_clients_before="$(count_control_for_session "$target_session")"
  log "  closing mirror workspace ${target_id} (session '$target_session', control clients on it: $target_clients_before)"

  local close_out
  close_out="$(cli workspace close "$target_id" 2>&1)"
  log "  close reply: $(printf '%s' "$close_out" | tr '\n' ' ' | cut -c1-160)"

  wait_edge "control client count drops below $ctl_before" 30 control_below "$ctl_before" || true
  local ctl_after; ctl_after="$(count_control)"
  # The remote half follows the client down a few seconds later.
  wait_edge "etterminal count drops below $ett_before" 30 etterminal_below "$ett_before" || true
  local ett_after et_after plain_after target_clients_after sessions_after
  ett_after="$(count_etterminal)"; et_after="$(count_etclient)"; plain_after="$(count_plain_clients)"
  target_clients_after="$(count_control_for_session "$target_session")"
  sessions_after="$(list_sessions)"
  local drop=$((ctl_before - ctl_after))
  local ett_drop=$((ett_before - ett_after))
  log "  after close: control=$ctl_after (drop $drop, need >=$EXPECT_DROP) etterminal=$ett_after (drop $ett_drop) et=$et_after"
  log "  session '$target_session' control clients: $target_clients_before -> $target_clients_after"

  local fails=""
  [ "$drop" -ge "$EXPECT_DROP" ] || fails="$fails; control clients dropped $drop, expected >=$EXPECT_DROP"
  [ "$drop" -le "$EXPECT_DROP" ] || fails="$fails; control clients dropped $drop, more than the one mirror closed"
  [ "$target_clients_after" -lt "$target_clients_before" ] || fails="$fails; session '$target_session' still has $target_clients_after control client(s)"
  [ "$ett_drop" -ge 1 ] || fails="$fails; remote etterminal count did not follow ($ett_before -> $ett_after)"
  [ "$plain_after" = "$plain_before" ] || fails="$fails; non-control clients changed ($plain_before -> $plain_after) — something detached a human's client"
  [ "$sessions_after" = "$sessions_before" ] || fails="$fails; host tmux sessions changed"

  local numbers="control ${ctl_before}->${ctl_after} (drop ${drop}, need >=${EXPECT_DROP}); etterminal ${ett_before}->${ett_after}; session '${target_session}' clients ${target_clients_before}->${target_clients_after}; et ${et_before}->${et_after}"
  if [ -n "$fails" ]; then
    record "$name" FAIL "$numbers${fails}"
  else
    record "$name" PASS "$numbers"
  fi
  reap "$name" || log "  reap left residue"
  record "$name-reap" INFO "$REAP_EVIDENCE"
  return 0
}
control_at_least() { [ "$(count_control)" -ge "$1" ]; }
etterminal_at_least() { [ "$(count_etterminal)" -ge "$1" ]; }
control_below() { [ "$(count_control)" -lt "$1" ]; }
etterminal_below() { [ "$(count_etterminal)" -lt "$1" ]; }

# ================================================================== case 2: DEAD-STREAM (bug B)

case_dead_stream() {
  local name="DEAD-STREAM"
  log ""
  log "=== $name (broker=$DEAD_BROKER) — an unpublishable stream must fail the RPC and leave nothing"
  if [ ! -x "$DEAD_BROKER_EXEC" ]; then
    record "$name" INCONCLUSIVE "broker $DEAD_BROKER_EXEC missing or not executable"
    return 0
  fi
  if ! ensure_dead_broker_registered; then
    record "$name" INCONCLUSIVE "could not register broker '$DEAD_BROKER' in $CMUX_JSON: $REG_STATUS"
    return 0
  fi
  log "  broker '$DEAD_BROKER' in $CMUX_JSON: $REG_STATUS (backup $CONFIG_BACKUP)"
  if ! require_clean_baseline; then
    record "$name" INCONCLUSIVE "baseline not clean: $BASELINE_EVIDENCE"
    return 0
  fi
  if ! launch_app; then
    record "$name" INCONCLUSIVE "tagged app did not come up"
    return 0
  fi

  local before_snap after_snap
  before_snap="$WORK_DIR/dead-before.tsv"; after_snap="$WORK_DIR/dead-after.tsv"
  snapshot_workspaces > "$before_snap"
  log "  workspaces before: $(grep -c . "$before_snap" || true)"

  # Sample the host's tmux clients and the remote ET halves across the attach and past it. This
  # is the positive artifact that binds the error verdict to a real transport: an unknown broker,
  # a typo or a dead etserver produces the same error with nothing ever arriving on the far end.
  # The window has to outlast the RPC. Measured here: the RPC gives up at the barrier (2.2s) and
  # cmux kills the local et clients, and only a second later do the remote halves' control
  # clients finish attaching — the leak this case exists to observe. Sampling only while the RPC
  # runs saw a peak of zero and graded a real transport as never reached.
  local sample="$WORK_DIR/dead-samples.txt" stop="$WORK_DIR/stop-sampler"
  rm -f "$stop"
  : > "$sample"
  (
    i=0
    while [ ! -f "$stop" ] && [ "$i" -lt 900 ]; do
      printf '%s %s\n' "$(count_control)" "$(count_etterminal)" >> "$sample"
      i=$((i + 1))
      sleep 0.2
    done
  ) &

  local t0 out rc
  t0="$(now)"
  out="$(cli ssh-tmux "$HOST" --transport et --broker "$DEAD_BROKER" 2>&1)"
  rc=$?
  local elapsed; elapsed="$(since "$t0")"
  printf '%s\n' "$out" > "$WORK_DIR/dead-attach.out"
  local reply
  reply="$(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-200)"
  log "  attach rc=$rc elapsed=${elapsed}s reply: $reply"

  # Edges, not a sleep: wait for the far end to show itself, with a bounded backstop. If neither
  # edge ever arrives the case is graded on peaks of zero, which is a FAIL by design.
  wait_edge "a remote ET half appears" 30 etterminal_at_least 1 || true
  wait_edge "a control client appears on the host's tmux" 30 control_at_least 1 || true
  touch "$stop"
  wait 2>/dev/null || true

  local peak_ctl peak_ett
  peak_ctl="$(awk '{ if ($1+0 > m) m = $1+0 } END { print m+0 }' "$sample")"
  peak_ett="$(awk '{ if ($2+0 > m) m = $2+0 } END { print m+0 }' "$sample")"
  local leaked_now; leaked_now="$(count_control)"
  log "  far end during/after attach: peak control clients=$peak_ctl peak etterminal=$peak_ett; still attached now=$leaked_now"

  # Counted after the settle window, so a barrier-disabled build has had every chance to show
  # the workspaces it left behind.
  snapshot_workspaces > "$after_snap"
  local new_ws
  new_ws="$(comm -13 "$before_snap" "$after_snap" | grep -c . || true)"
  log "  workspaces after: $(grep -c . "$after_snap" || true) (new: $new_ws)"
  if [ "$new_ws" != "0" ]; then
    comm -13 "$before_snap" "$after_snap" | while IFS= read -r line; do log "    leftover: $line"; done
  fi

  local want_error=1
  [ "$BREAK_ORACLE" = "dead-ok" ] && want_error=0

  local fails=""
  if [ "$want_error" = 1 ]; then
    case "$out" in
      *"$DEAD_ERROR_NEEDLE"*) ;;
      *) fails="$fails; reply did not carry '$DEAD_ERROR_NEEDLE'" ;;
    esac
    [ "$rc" != "0" ] || fails="$fails; attach exited 0 on a stream cmux cannot publish"
    [ "$new_ws" = "0" ] || fails="$fails; $new_ws workspace(s) left behind wired to nothing"
  else
    # Self-test arm: demand the barrier-disabled signature (ok plus workspaces) from a build
    # that has the barrier. It must FAIL.
    [ "$rc" = "0" ] || fails="$fails; attach did not answer ok (rc=$rc)"
    [ "$new_ws" != "0" ] || fails="$fails; no workspace was left wired to nothing"
  fi
  # Bound the verdict to evidence the case reached the far end, whichever arm it is.
  [ "$peak_ett" -ge 1 ] || fails="$fails; no remote ET half ever started, so the case never reached the transport"
  [ "$peak_ctl" -ge 1 ] || fails="$fails; no control client ever appeared on the host's tmux, so the attach never reached tmux"

  local numbers="rc=$rc elapsed=${elapsed}s; peak control clients=$peak_ctl; peak etterminal=$peak_ett; leftover workspaces=$new_ws; reply=\"$reply\""
  if [ -n "$fails" ]; then
    record "$name" FAIL "$numbers${fails}"
  else
    record "$name" PASS "$numbers"
  fi
  # This is the case that is known to leak: the barrier refuses every mirror and the teardown
  # cannot confirm a detach over a stream too noisy to answer.
  reap "$name" || log "  reap left residue"
  record "$name-reap" INFO "$REAP_EVIDENCE"
  restore_config
  return 0
}

# ============================================================================== drive the cases

if [ $# -eq 0 ]; then
  set -- HEALTHY-DETACH DEAD-STREAM
fi

log "remote-tmux-fuzz-run  tag=$TAG host=$HOST hairpin=$HAIRPIN"
log "  app     : $APP_BUNDLE"
log "  tmux    : $TMUX_BIN -S $TMUX_SOCKET"
log "  workdir : $WORK_DIR"
[ -n "$BREAK_ORACLE" ] && log "  SELF-TEST: FUZZ_BREAK_ORACLE=$BREAK_ORACLE (this run is expected to FAIL)"

if [ ! -d "$APP_BUNDLE" ]; then
  log "app bundle not found; build it first: ./scripts/reload.sh --tag $TAG"
  exit 3
fi
if ! tmx list-sessions >/dev/null; then
  log "no tmux server on $TMUX_SOCKET — the host cmux mirrors has nothing to attach to"
  exit 3
fi

for c in "$@"; do
  case "$c" in
    HEALTHY-DETACH) case_healthy_detach ;;
    DEAD-STREAM) case_dead_stream ;;
    *) log "unknown case: $c"; exit 64 ;;
  esac
  # A case that fell out without grading itself must not disappear from the tally: silence has
  # to read as a failure, never as a pass.
  if ! awk -F'\t' -v n="$c" '$1==n' "$RESULT_FILE" | grep -q .; then
    record "$c" FAIL "case produced no verdict"
  fi
done

log ""
log "================================ RESULTS ================================"
awk -F'\t' '{ printf "%-18s %-13s %s\n", $1, $2, $3 }' "$RESULT_FILE" | tee -a "$LOG_FILE"
pass=$(awk -F'\t' '$2=="PASS"' "$RESULT_FILE" | wc -l | tr -d ' ')
fail=$(awk -F'\t' '$2=="FAIL"' "$RESULT_FILE" | wc -l | tr -d ' ')
inconc=$(awk -F'\t' '$2=="INCONCLUSIVE"' "$RESULT_FILE" | wc -l | tr -d ' ')
log "TALLY pass=$pass fail=$fail inconclusive=$inconc   log=$LOG_FILE"

if [ "$fail" != "0" ]; then exit 1; fi
if [ "$inconc" != "0" ]; then exit 2; fi
exit 0
