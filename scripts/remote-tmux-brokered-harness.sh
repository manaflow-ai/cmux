#!/bin/bash
# remote-tmux-brokered-harness.sh — does cmux's own remote-tmux wire shape work when the host
# is reached through an ssh/et broker instead of directly?
#
# The harness sends what cmux sends: the broker argv shape the ET profile builds, the quoted
# `exec 'tmux' '-CC' 'new-session' '-t' <session>` control-stream command against a session a
# one-shot created first, and a command sized to exactly cmux's delivery budget. If the checks
# pass, cmux works here for the same reasons the harness did.
#
# A brokered connection needs a human security-key touch, so a run is interactive by design. It
# prints its plan, banners each check into the pane before prompting, and waits on observed
# edges rather than sleeps. The transport runs at a real terminal in a real tmux pane: nothing
# captures its stdout or stdin, which is what lets the prompt reach the human and the human's
# passcode reach the client.
#
# Two rules the checks here are built around, both learned by getting them wrong:
#
#   A verdict must not be satisfiable by anything cheaper than the claim. et TYPES the command
#   into a remote shell, so the shell echoes it back, and every success string that appears
#   literally in the typed command can be matched in that echo. So no success string is typed:
#   the remote computes each marker value from a seed (`v=$((SEED*7)); echo S$v`), and the
#   harness looks for the computed value, which exists nowhere in the input.
#
#   Absence of output is not evidence of a cut. A shell that received everything and executed
#   nothing looks identical to a truncated line, so a length probe prints a start marker before
#   its padding: no start means the measurement did not happen, start without end means a cut.
#
# Modes:
#   harness.sh run       real run against HOST. One key touch per connection; plan printed first.
#   harness.sh selftest  self-validation against a substitute broker: no network, no auth, its
#                        own private tmux socket. Fails unless every verdict is shown able to
#                        report both outcomes.
#   harness.sh cleanup   one connection to remove sessions an aborted run left behind.
#   harness.sh _fake ... internal: the substitute broker used by selftest.
set -u

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
MODE="${1:-}"

# Private by default. The harness writes wrapper scripts here and then executes them, so a
# world-writable shared path would let another local user swap a wrapper between write and run,
# or forge log bytes and fabricate any verdict.
WORKDIR="${WORKDIR:-/tmp/cmux-brokered-harness-$(id -u)}"
TMUX_BIN="${TMUX_BIN:-/opt/homebrew/bin/tmux}"
[ -x "$TMUX_BIN" ] || TMUX_BIN="$(command -v tmux || true)"
# When set, every tmux call goes to this socket explicitly rather than relying on TMUX_TMPDIR,
# which is inherited and easy to get wrong.
TM_SOCKET="${TM_SOCKET:-}"
PANE="${PANE:-}"
# No default on purpose: the broker is site-specific, and guessing a path would make this harness
# describe one organisation's tooling rather than the contract cmux actually models.
BROKER="${BROKER:-}"
# Flags the broker takes before the destination — cmux models these as the broker's leading
# arguments. Ordering is load-bearing: a client flag placed before the destination is rejected
# outright and the wrapper exits without connecting.
# ${VAR-default}, not ${VAR:-default}: a caller passing an empty list means "no flags", and the
# colon form silently substituted the wrapper's flags back in for the direct mode.
BROKER_ARGS="${BROKER_ARGS--et -fallback}"
# Which argv shape the client takes. cmux builds both:
#   broker  <flags> <destination> -c <command>   the wrapper parses up to the destination and
#                                               forwards the rest, so a client flag placed
#                                               before the destination is rejected outright
#   direct  <flags> -c <command> <destination>   et's own order, destination last
# Same checks either way, which is the point: the brokered path should measure the same as the
# direct one, and a local etserver needs no 2FA, so the direct mode is runnable unattended.
TRANSPORT_MODE="${TRANSPORT_MODE:-broker}"
case "$TRANSPORT_MODE" in broker|direct) ;; *) echo "TRANSPORT_MODE must be broker or direct" >&2; exit 64;; esac
HOST="${HOST:-}"
QUESTIONS="${QUESTIONS:-1 2 3 4 5 6 7}"
AUTH_TIMEOUT="${AUTH_TIMEOUT:-300}"   # how long a human gets to notice and touch the key
# Between "an OTP was submitted" and "the remote shell echoed the command" the broker still has
# work to do, and on a real host that gap ran past two minutes. It is a different wait from the
# human one and gets its own budget; folding the two together is what made a working connection
# get written off while it was still coming up.
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-240}"
OP_TIMEOUT="${OP_TIMEOUT:-30}"        # once the connection is provably up, results are fast
POLL="${POLL:-0.2}"
CAPTURE_LINES="${CAPTURE_LINES:-800}"
# cmux's own numbers, so a pass is a statement about cmux rather than about a round number.
# BUDGET_BYTES is RemoteTmuxETTransportProfile.deliverableCommandBytes; OVER_BYTES is past any
# MAX_CANON cmux expects to meet (1024 on macOS, 4096 on Linux), so it must be cut.
BUDGET_BYTES="${BUDGET_BYTES:-928}"
OVER_BYTES="${OVER_BYTES:-4200}"
# Which tmux verb the control-stream check sends. Measured on a real host, these differ: attach
# answered the handshake and then sent %exit with no window, while the grouped form stayed live. The
# harness must be able to send either, and defaults to the one cmux ships.
CONTROL_VERB="${CONTROL_VERB:-attach-session}"
case "$CONTROL_VERB" in
  attach-session|new-session) ;;
  *) printf 'CONTROL_VERB must be attach-session or new-session\n' >&2; exit 64;;
esac
RUNID="${RUNID:-r$(date +%s)_$$}"
# Marker values are derived from this, not from RUNID, because RUNID is not always numeric.
SEED_BASE="${SEED_BASE:-$(date +%s)}"

# ---------- small utilities ----------
say()  { printf '%s\n' "$*"; }
# note goes to stderr: helpers are used in command substitution and their stdout must carry
# only the value asked for, never a progress message.
note() { printf '[harness] %s\n' "$*" >&2; }
die()  { printf '[harness] FATAL: %s\n' "$*" >&2; exit 70; }

VERDICT_FILE=""
verdict() { # verdict <Qn> <STATUS> <evidence...>
  local q="$1" st="$2"; shift 2
  printf 'VERDICT %s: %s | %s\n' "$q" "$st" "$*" | tee -a "$VERDICT_FILE"
}

want() { case " $QUESTIONS " in *" $1 "*) return 0;; *) return 1;; esac; }

tm() {
  if [ -n "$TM_SOCKET" ]; then "$TMUX_BIN" -S "$TM_SOCKET" "$@"; else "$TMUX_BIN" "$@"; fi
}

# RUNID and SEED_BASE reach remote shell commands and cleanup regexes, so keep them to
# characters that mean nothing to either.
validate_ids() {
  case "$RUNID" in
    ""|*[!A-Za-z0-9_]*) die "RUNID must be non-empty and only A-Za-z0-9_ (got: $RUNID)";;
  esac
  case "$SEED_BASE" in
    ""|*[!0-9]*) die "SEED_BASE must be a positive integer (got: $SEED_BASE)";;
  esac
}

# The wrapper scripts here get executed, so the directory has to be ours and only ours.
workdir_init() {
  mkdir -p -m 700 "$WORKDIR" 2>/dev/null || die "cannot create $WORKDIR"
  [ -L "$WORKDIR" ] && die "$WORKDIR is a symlink; refusing to write wrapper scripts through it"
  local owner perms
  owner=$(stat -f '%u' "$WORKDIR" 2>/dev/null || stat -c '%u' "$WORKDIR" 2>/dev/null || echo "")
  perms=$(stat -f '%Lp' "$WORKDIR" 2>/dev/null || stat -c '%a' "$WORKDIR" 2>/dev/null || echo "")
  [ "$owner" = "$(id -u)" ] || die "$WORKDIR is owned by uid ${owner:-unknown}, not $(id -u)"
  case "$perms" in
    700|500) ;;
    *) chmod 700 "$WORKDIR" || die "cannot restrict $WORKDIR (mode $perms)";;
  esac
  VERDICT_FILE="$WORKDIR/verdicts.txt"
}

# ---------- markers computed on the remote ----------
# MK is typed; MV is what the remote prints. Nothing the harness greps for exists in its input,
# so an echo, a zle redraw, or an xtrace line cannot satisfy a verdict.
# A marker printed on its own line is anchored on the control bytes in front of it, not on a
# bare CR/LF. A real line limit BEEPS, so a truncated probe's start marker arrives as
# "\a S<value>" (measured), and a CR/LF-only anchor rejected it — which made every genuine cut
# unmeasurable. Control bytes are allowed in front; printable text is not, so `echo S$v` in the
# command echo still cannot satisfy it.
CTRL_ANCHOR='[\x00-\x1f]+'
MARK_SEQ=0; MK=""; MV=""
next_marker() {
  MARK_SEQ=$((MARK_SEQ + 1))
  MK=$((SEED_BASE + MARK_SEQ * 1000))
  MV=$((MK * 7))
}
# The prefix every remote command starts with, which teaches the remote its marker value.
marker_prefix() { printf 'v=$((%s*7)); ' "$MK"; }

# Shared by every marker matcher below. Kept as a python fragment rather than a shell regex so
# there is one definition and no re-escaping through the shell.
read -r -d '' MARKER_ANCHOR_PY <<'ANCHORPY'
ESCSEQ = (rb'(?:'
          rb'\x1b\[[0-9;?]*[A-Za-z]'          # CSI ... final
          rb'|\x1bk[^\x1b]*\x1b\\'           # ESC k <title> ST  (tmux/screen title)
          rb'|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)'  # OSC ... BEL or ST
          rb'|\x1b[PX^_][^\x1b]*\x1b\\'      # DCS/SOS/PM/APC ... ST
          rb'|\x1b\\'                        # bare ST
          rb'|\x1b[>=()#][0-9A-Za-z]?'       # short escapes
          rb')')
ANCHOR = rb'(?:[\x00-\x1f]|' + ESCSEQ + rb')+'
ANCHORPY

# ---------- pane driving ----------
pane_send() { # type a line into the pane and press Enter
  tm send-keys -t "$PANE" -l "$1"
  tm send-keys -t "$PANE" Enter
}
pane_enter() { tm send-keys -t "$PANE" Enter; }
pane_text() { tm capture-pane -p -J -t "$PANE" -S "-${CAPTURE_LINES}" 2>/dev/null; }
pane_banner() { pane_send "clear; echo; echo \"### cmux harness: $1\"; echo"; }

# Banner for a check that costs a touch. The number comes from a counter, because hand-written
# "2/5" strings go stale as soon as checks start sharing connections.
TAP_NO=0; TAP_TOTAL=0
check_banner() { TAP_NO=$((TAP_NO + 1)); pane_banner "tap ${TAP_NO}/${TAP_TOTAL}: $1"; }

# Type a control-stream command only while the connection is open. Unguarded, this types tmux
# commands into the pane's own shell after the connection closed.
pane_send_live() { # <line> <description>
  if conn_done; then
    note "did not type '$2': connection ${CONN_TAG} had already closed"
    return 1
  fi
  pane_send "$1"
}

# The pane being driven is often not the window the human is looking at — a run can sit at a
# passcode prompt for its whole budget while they watch a different session. So the prompt is
# announced on every attached client's status line, not only in the pane, and re-announced while
# no OTP has been echoed. Without this a correct harness still measures nothing.
alert_clients() { # <text>
  local ttys t
  ttys=$(tm list-clients -F '#{client_tty}' 2>/dev/null)
  for t in $ttys; do
    tm display-message -c "$t" -d 4000 "$1" 2>/dev/null || true
  done
}

# ---------- edge waiting ----------
wait_pane() { # <plain-text-needle> <timeout-s> <description>
  local needle="$1" to="$2" desc="$3" t0 now
  t0=$(date +%s)
  while :; do
    pane_text | grep -F -q "$needle" && return 0
    now=$(date +%s)
    if [ $((now - t0)) -ge "$to" ]; then
      note "TIMEOUT after ${to}s waiting for: $desc"
      return 1
    fi
    sleep "$POLL"
  done
}

# wait_bytes <file> <bytes-regex> <timeout-s> <start-offset> <description>
# Prints the match start offset on success. rc 0 found, 1 timeout.
wait_bytes() {
  local f="$1" rx="$2" to="$3" off="${4:-0}" desc="$5" rc
  python3 - "$f" "$rx" "$to" "$off" "$POLL" <<'PY'
import re, sys, time
f, rx, to, off, poll = sys.argv[1], sys.argv[2], float(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
pat = re.compile(rx.encode('utf-8').decode('unicode_escape').encode('latin-1'), re.S)
end = time.time() + to
while True:
    try:
        data = open(f, 'rb').read()
    except FileNotFoundError:
        data = b''
    m = pat.search(data, off)
    if m:
        print(m.start())
        sys.exit(0)
    if time.time() >= end:
        sys.exit(1)
    time.sleep(poll)
PY
  rc=$?
  [ $rc -ne 0 ] && note "TIMEOUT after ${to}s waiting for: $desc"
  return $rc
}

# wait_marker <marker-regex> <timeout> <description>
# The marker text is a plain regex (e.g. "S12492910962" or "K123=(created|failed)"); the anchor
# and the trailing line boundary are added here.
wait_marker() {
  local mark="$1" to="$2" desc="$3" rc
  python3 - "$CONN_LOG" "$mark" "$to" "$POLL" <<PYMARK
import re, sys, time
$MARKER_ANCHOR_PY
log, mark, to, poll = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
pat = re.compile(ANCHOR + mark.encode() + rb'(?=[\r\n])')
end = time.time() + to
while True:
    try:
        data = open(log, 'rb').read()
    except FileNotFoundError:
        data = b''
    m = pat.search(data)
    if m:
        print(m.start())
        sys.exit(0)
    if time.time() >= end:
        sys.exit(1)
    time.sleep(poll)
PYMARK
  rc=$?
  [ $rc -ne 0 ] && note "TIMEOUT after ${to}s waiting for: $desc"
  return $rc
}

# wait_block <file> <offset> <timeout> <inner-regex-or-empty> <description>
# Waits for a COMPLETE control-mode block: %begin id num flags ... %end id num flags with the
# same three fields. Matching the two lines independently is not the same thing — a truncated
# block plus an unrelated later %end satisfies that, and so does asynchronous %output text.
wait_block() {
  local f="$1" off="$2" to="$3" inner="$4" desc="$5" rc
  python3 - "$f" "$off" "$to" "$inner" "$POLL" <<'PY'
import re, sys, time
f, off, to, inner, poll = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4], float(sys.argv[5])
begin = re.compile(rb'%begin (\d+) (\d+) (\d+)')
inner_pat = re.compile(inner.encode('utf-8').decode('unicode_escape').encode('latin-1'), re.S) if inner else None
end_at = time.time() + to
while True:
    try:
        data = open(f, 'rb').read()
    except FileNotFoundError:
        data = b''
    pos = off
    while True:
        m = begin.search(data, pos)
        if not m:
            break
        i, n, fl = m.groups()
        closer = re.compile(rb'%end ' + re.escape(i) + rb' ' + re.escape(n) + rb' ' + re.escape(fl))
        me = closer.search(data, m.end())
        if not me:
            break
        body = data[m.end():me.start()]
        if inner_pat is None or inner_pat.search(body):
            print(m.start())
            sys.exit(0)
        pos = me.end()
    if time.time() >= end_at:
        sys.exit(1)
    time.sleep(poll)
PY
  rc=$?
  [ $rc -ne 0 ] && note "TIMEOUT after ${to}s waiting for: $desc"
  return $rc
}

# wait_delivery <echo-needle-regex> <description>
# Three states, two budgets, and a retry. AUTH_STATE ends as:
#   none       nothing recognizable arrived; the measurement never started
#   submitted  an OTP was echoed — submitted, NOT necessarily accepted
#   delivered  the remote shell echoed the command, so there is something to grade
# A rejected OTP hands control back to the human, so it restarts the human budget instead of
# spending the connect budget waiting for a connection that was never authorized.
AUTH_STATE=""
wait_delivery() {
  local needle="$1" desc="$2" out rc
  out=$(python3 - "$CONN_LOG" "$needle" "$AUTH_TIMEOUT" "$CONNECT_TIMEOUT" "$POLL" "$desc" <<'PY'
import re, sys, time
log, needle, auth_to, conn_to, poll, desc = sys.argv[1:7]
auth_to, conn_to, poll = float(auth_to), float(conn_to), float(poll)
cmd = re.compile(needle.encode('utf-8').decode('unicode_escape').encode('latin-1'), re.S)
otp = re.compile(rb'Passcode: [A-Za-z0-9]{8,}')
reject = re.compile(rb'[Ii]ncorrect passcode')
state, budget, t0, seen_otp, seen_rejects = 'none', auth_to, time.time(), 0, 0
while True:
    try:
        data = open(log, 'rb').read()
    except FileNotFoundError:
        data = b''
    if cmd.search(data):
        print('STATE=delivered')
        sys.exit(0)
    rejects = len(reject.findall(data))
    if rejects > seen_rejects:
        seen_rejects = rejects
        state, budget, t0, seen_otp = 'none', auth_to, time.time(), 0
        sys.stderr.write('[harness] the host rejected an OTP (%d); waiting again for a fresh one\n' % rejects)
    otps = len(otp.findall(data))
    if otps > seen_otp:
        seen_otp = otps
        state, budget, t0 = 'submitted', conn_to, time.time()
        sys.stderr.write('[harness] an OTP was submitted; up to %ds for the broker to deliver the command\n' % conn_to)
    if time.time() - t0 >= budget:
        sys.stderr.write('[harness] TIMEOUT after %ds waiting for: %s\n' % (budget, desc))
        print('STATE=' + state)
        sys.exit(1)
    time.sleep(poll)
PY
)
  rc=$?
  AUTH_STATE="${out#STATE=}"
  return $rc
}

delivery_failure_detail() {
  if [ "$AUTH_STATE" = submitted ]; then
    printf 'an OTP was echoed (submitted, not necessarily accepted) but no command echo followed within %ss' "$CONNECT_TIMEOUT"
  else
    printf 'nothing recognizable arrived within %ss: no OTP was echoed and no command echo appeared' "$AUTH_TIMEOUT"
  fi
}

# ---------- connection lifecycle ----------
CONN_TAG=""; CONN_LOG=""; CONN_SH=""; HEARTBEAT_PID=""; RECORDER_PID=""; PANE_REC=""

# A wait that can last minutes has to prove it is still a wait. The heartbeat answers "waiting
# for what?" from the run log alone; the recorder keeps what the human saw, which the transport
# log cannot show (a pane can blank or wedge for reasons that never reach that stream).
start_heartbeat() {
  local tag="$1" log="$CONN_LOG"
  (
    while :; do
      sleep 10
      if ! grep -aqE 'Passcode: [A-Za-z0-9]{8,}' "$log" 2>/dev/null; then
        alert_clients "cmux harness: waiting for your security key — tap ${TAP_NO}/${TAP_TOTAL} is prompting in ${PANE}"
      fi
      printf '[harness] %s: %sB in raw log | transport: %s | pane: %s\n' "$tag" \
        "$(wc -c < "$log" 2>/dev/null | tr -d ' ')" \
        "$(tr -d '\r' < "$log" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-90)" \
        "$(pane_text 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-60)" >&2
    done
  ) &
  HEARTBEAT_PID=$!
  disown "$HEARTBEAT_PID" 2>/dev/null
}

snapshot_pane() { # one timestamped pane snapshot, appended
  local cur; cur=$(pane_text 2>/dev/null)
  printf '=== %s (%s bytes visible)\n%s\n' "$(date +%H:%M:%S)" "${#cur}" "$cur" >> "$PANE_REC"
}

start_recorder() {
  PANE_REC="$WORKDIR/pane_${CONN_TAG}.log"
  (
    last=""
    while :; do
      cur=$(pane_text 2>/dev/null)
      if [ "$cur" != "$last" ]; then
        printf '=== %s (%s bytes visible)\n%s\n' "$(date +%H:%M:%S)" "${#cur}" "$cur" >> "$PANE_REC"
        last=$cur
      fi
      sleep 1
    done
  ) &
  RECORDER_PID=$!
  disown "$RECORDER_PID" 2>/dev/null
}

# Snapshot first, then stop. Killing the recorder before a final capture loses the last second
# of the pane, which is exactly where a connection's closing marker lands.
stop_watchers() {
  if [ -n "$PANE_REC" ]; then snapshot_pane; fi
  [ -n "$HEARTBEAT_PID" ] && kill "$HEARTBEAT_PID" 2>/dev/null
  [ -n "$RECORDER_PID" ] && kill "$RECORDER_PID" 2>/dev/null
  HEARTBEAT_PID=""; RECORDER_PID=""
}

# On any exit, stop the watchers and make sure no transport wrapper is left running in the pane.
harness_teardown() {
  stop_watchers
  if [ -n "$CONN_SH" ] && { pgrep -f "$CONN_SH" >/dev/null 2>&1 || pgrep -f "$CONN_LOG" >/dev/null 2>&1; }; then
    note "exiting with connection ${CONN_TAG} still alive; killing its local client"
    pkill -f "$CONN_SH" 2>/dev/null
    pkill -f "$CONN_LOG" 2>/dev/null
  fi
}
trap 'harness_teardown' EXIT

# launch_conn <shorttag> <remote-command>
# script(1) keeps the RAW byte stream (capture-pane loses the ESC P 1000 p handshake, since the
# terminal swallows it) and relays stdin, so the auth prompt still reaches the human. The
# wrapper echoes a per-launch nonce when the local client exits, so a stale marker in old
# scrollback cannot end this connection's wait.
CONN_NONCE=""
launch_conn() {
  local rcmd="$2"
  CONN_TAG="${RUNID}_$1"
  CONN_NONCE="${CONN_TAG}_${RANDOM}${RANDOM}"
  CONN_LOG="$WORKDIR/conn_${CONN_TAG}.log"
  CONN_SH="$WORKDIR/conn_${CONN_TAG}.sh"
  : > "$CONN_LOG"
  {
    printf '#!/bin/bash\n'
    # -F -t 0: flush the raw log on every write. Without it macOS script(1) flushes every 30s,
    # so a live connection shows an empty log while it is working.
    printf '/usr/bin/script -qF -t 0 %q %q' "$CONN_LOG" "$BROKER"
    # shellcheck disable=SC2086 -- BROKER_ARGS is a deliberately word-split flag list
    local a; for a in $BROKER_ARGS; do printf ' %q' "$a"; done
    if [ "$TRANSPORT_MODE" = direct ]; then
      printf ' -c %q %q\n' "$rcmd" "$HOST"
    else
      printf ' %q -c %q\n' "$HOST" "$rcmd"
    fi
    printf 'rc=$?\n'
    # A tmux -CC stream wraps itself in a DCS. If the connection died mid-stream the pane is
    # still swallowing bytes into it and the marker below would be invisible, so end any pending
    # DCS with an ST first (harmless otherwise).
    printf '%s\n' "printf '\\033\\\\'"
    printf 'echo "CONN_DONE_%s rc=$rc"\n' "$CONN_NONCE"
  } > "$CONN_SH"
  chmod 700 "$CONN_SH"
  # Old scrollback can hold a previous connection's marker; start each one from a clean pane.
  tm clear-history -t "$PANE" 2>/dev/null
  note "connection ${CONN_TAG}: touch your security key when the pane prompts (up to ${AUTH_TIMEOUT}s)"
  tm set-option -w -t "$PANE" monitor-activity on 2>/dev/null || true
  alert_clients "cmux harness: tap ${TAP_NO}/${TAP_TOTAL} — a passcode prompt is coming in ${PANE}"
  start_recorder
  start_heartbeat "$CONN_TAG"
  pane_send "bash '$CONN_SH'"
}

conn_done() { pane_text | grep -F -q "CONN_DONE_${CONN_NONCE} rc="; }
wait_conn_done() { wait_pane "CONN_DONE_${CONN_NONCE} rc=" "$1" "connection ${CONN_TAG} to close"; }

close_conn() { # wrapper so watchers stop on every path out, including the failure paths
  local rc=0
  close_conn_inner || rc=$?
  stop_watchers
  CONN_SH=""
  return $rc
}

# Escalate in bounded steps. Typing `exit` is only ever right when the command actually reached
# a remote shell. Measured: a truncated line loses its excess bytes and its terminating newline
# together, so the shell holds a partial line and has run nothing — it is not at a prompt, and it
# needs a terminator before it needs an exit. With no delivery at all there is no shell to type
# at, and the keystrokes land wherever the transport's stdin goes — measured once as
# `Passcode: exit` typed at a live 2FA passcode prompt, answered with "Incorrect passcode", which is
# useless and a step toward locking the account.
close_conn_inner() {
  wait_conn_done "$OP_TIMEOUT" && return 0
  if [ "$AUTH_STATE" = delivered ] && ! conn_done; then
    # Measured: a line over the canonical limit loses its excess AND its newline, so the remote
    # shell is not sitting at a prompt — it is mid-line with nothing run. It needs a terminator
    # first, and that terminator makes the truncated line execute, which leaves the shell at a
    # prompt needing an exit of its own. One keystroke cannot do both jobs.
    note "connection ${CONN_TAG} still open; supplying a line terminator, then exiting the remote shell"
    conn_done || pane_enter
    wait_conn_done 3 && return 0
    conn_done || pane_send "exit"
    wait_conn_done 8 && return 0
    conn_done || pane_send "exit"
    wait_conn_done 8 && return 0
  else
    note "connection ${CONN_TAG} still open and nothing was delivered; not typing at an unknown prompt"
  fi
  note "connection ${CONN_TAG} still open; sending Ctrl-C"
  tm send-keys -t "$PANE" C-c
  wait_conn_done 5 && return 0
  note "connection ${CONN_TAG} still open; killing the local client (script wrapper)"
  # Two patterns, because they are two processes: the wrapper's argv carries the .sh path, while
  # the script(1) process that actually holds the transport carries the log path. Killing only
  # the wrapper leaves the client running and its CONN_DONE echo never happens, so the close
  # times out and the run aborts on a connection that could have been closed.
  pkill -f "$CONN_SH" 2>/dev/null
  pkill -f "$CONN_LOG" 2>/dev/null
  wait_conn_done 8 && return 0
  note "ATTENTION: connection ${CONN_TAG} could not be closed; later checks would run against a live client"
  return 1
}

# Any check that cannot close its connection ends the run: a later probe typed into a live
# client measures the wrong thing while earlier PASS verdicts stay on the record.
close_or_abort() {
  close_conn && return 0
  verdict RUN ABORTED "connection ${CONN_TAG} could not be closed, so no further check can be trusted; the pane needs manual attention"
  say ""
  say "==== SUMMARY (run ${RUNID}, ABORTED) ===="
  sed 's/^/  /' "$VERDICT_FILE" 2>/dev/null
  exit 75
}

# ---------- checks 1 + 2: does -c reach a login shell that resolves tmux? ----------
# whence -p, not command -v: command -v answers for aliases and functions too, while cmux's
# quoted 'tmux' suppresses both. A host with a tmux alias and no binary would pass on
# command -v and then fail to reach control mode.
login_probe_command() {
  printf 'echo L$v=$([[ -o login ]] && echo yes || echo no) T$v=$(whence -p tmux || echo none)'
}
# Anchored at both ends so neither the echoed command nor an xtrace line (which starts with +)
# can satisfy it, and so a half-flushed line cannot be read as a result.
login_result_needle() { printf '%sL%s=(yes|no) T%s=[^ \\r\\n]+[\\r\\n]' "$CTRL_ANCHOR" "$MV" "$MV"; }

# Both values come from ONE match of that line. Read separately, the second key — which sits
# mid-line after the first — could never be found at a line start at all.
login_result_values() {
  python3 - "$CONN_LOG" "$MV" <<PYVALS
import re, sys
$MARKER_ANCHOR_PY
try:
    data = open(sys.argv[1], 'rb').read()
except FileNotFoundError:
    sys.exit(0)
mv = re.escape(sys.argv[2].encode())
pat = re.compile(ANCHOR + rb'L' + mv + rb'=(\S+) T' + mv + rb'=(\S+)')
hits = pat.findall(data)
if hits:
    print(hits[-1][0].decode('latin-1'), hits[-1][1].decode('latin-1'))
PYVALS
}

grade_login() { # emits checks 1 and 2 from a log that already delivered the probe
  local vals login tmuxp
  vals=$(login_result_values)
  if [ -n "$vals" ]; then login=${vals%% *}; tmuxp=${vals#* }; else login=""; tmuxp=""; fi
  want 1 && verdict Q1 PASS "the broker forwarded -c and the remote shell ran it (computed marker ${MV} came back)"
  if [ "$login" = yes ] && [ -n "$tmuxp" ] && [ "$tmuxp" != none ]; then
    want 2 && verdict Q2 PASS "the shell is a login shell ([[ -o login ]]=yes) and resolves a bare tmux to ${tmuxp}, which is why cmux may drop the PATH resolver ssh needs"
  else
    want 2 && verdict Q2 FAIL "login=${login:-?} tmux=${tmuxp:-?}; cmux cannot rely on sending a bare tmux here"
  fi
}

# marker_value <KEY>: the value of KEY=... on a line of its own, so the echoed command's copy
# (always followed by $( ) is never read as a result.
marker_value() {
  python3 - "$CONN_LOG" "$1" <<PY
import re, sys
$MARKER_ANCHOR_PY
try:
    data = open(sys.argv[1], 'rb').read()
except FileNotFoundError:
    sys.exit(0)
key = re.escape(sys.argv[2].encode())
m = re.findall(ANCHOR + key + rb'=([^\s]*)', data)
print(m[-1].decode('latin-1') if m else '')
PY
}

q12_run() {
  next_marker
  local rcmd; rcmd="$(marker_prefix)$(login_probe_command)"
  check_banner "does the broker's -c reach a login shell with tmux on PATH?"
  launch_conn q12 "$rcmd"
  if ! wait_delivery "$MK" "checks 1-2: command delivery"; then
    verdict Q1 INCONCLUSIVE "$(delivery_failure_detail)"
    verdict Q2 INCONCLUSIVE "cannot measure: the probe was never delivered"
    close_or_abort; return
  fi
  if wait_marker "L${MV}=(yes|no) T${MV}=[^ ]+" "$OP_TIMEOUT" "checks 1-2: probe result" >/dev/null; then
    grade_login
  else
    verdict Q1 FAIL "the command was typed into the remote shell (its echo is in the log) but produced no result line"
    verdict Q2 INCONCLUSIVE "cannot measure: the probe produced no result"
  fi
  close_or_abort
}

# ---------- check 3: does cmux's delivery budget fit this transport? ----------
# The start marker runs before the padding, so a cut is proven positively rather than inferred
# from silence. Payload stays quote-free: a cut inside a quote parks the remote shell on a
# continuation prompt instead of a normal one.
PROBE_RESULT=""; PROBE_DETAIL=""
q3_probe() { # <label> <total-command-byte-length> <banner>
  next_marker
  local label="$1" target="$2" banner="$3" prefix suffix padlen pad rcmd
  prefix="$(marker_prefix)echo S\$v; : "
  suffix="; echo E\$v"
  padlen=$(( target - ${#prefix} - ${#suffix} ))
  [ "$padlen" -lt 1 ] && padlen=1
  pad=$(python3 -c "import sys; sys.stdout.write('A'*int(sys.argv[1]))" "$padlen")
  rcmd="${prefix}${pad}${suffix}"
  check_banner "$banner"
  launch_conn "q3_${label}" "$rcmd"
  PROBE_RESULT=inconc; PROBE_DETAIL=""
  if ! wait_delivery "$MK" "check 3 ${label}: delivery"; then
    PROBE_DETAIL="$(delivery_failure_detail)"
    close_or_abort; return
  fi
  # A whole line runs on its own, so the end marker is the pass condition. Anything short of it
  # has to account for how truncation actually works: an over-limit line loses its excess bytes
  # and its terminating newline together, so the remote shell holds a partial line and runs
  # NOTHING — not even the start marker. Supplying the missing newline then executes exactly the
  # part that arrived, so a start marker appearing only after that Enter is positive proof that a
  # partial line was buffered, and its absence means nothing ever reached a shell.
  if wait_marker "E${MV}" "$OP_TIMEOUT" "check 3 ${label}: end marker (whole line)" >/dev/null; then
    PROBE_RESULT=pass
    note "probe ${label} (${#rcmd}B): the end marker ran, so the line arrived whole"
    close_or_abort; return
  fi
  note "probe ${label} (${#rcmd}B): no end marker; supplying the line terminator a cut line never receives"
  conn_done || pane_enter
  if wait_marker "S${MV}" "$OP_TIMEOUT" "check 3 ${label}: start marker after a supplied terminator" >/dev/null; then
    if wait_marker "E${MV}" 3 "check 3 ${label}: end marker after a supplied terminator" >/dev/null; then
      PROBE_RESULT=inconc
      PROBE_DETAIL="the whole command was present and ran once a newline was supplied, so nothing was cut and this probe says nothing about a length limit"
    else
      PROBE_RESULT=fail
      note "probe ${label}: the buffered partial line ran and stopped before the end marker, so the line was cut"
    fi
  else
    PROBE_RESULT=inconc
    PROBE_DETAIL="no marker ran even after a newline was supplied, so the command never reached a shell and no statement about length is possible"
  fi
  close_or_abort
}

q3_run() {
  q3_probe budget "$BUDGET_BYTES" \
    "does a command sized to cmux's exact budget (${BUDGET_BYTES}B) survive delivery?"
  case "$PROBE_RESULT" in
    inconc)
      verdict Q3 INCONCLUSIVE "the ${BUDGET_BYTES}B budget probe was not measured: ${PROBE_DETAIL}"
      return;;
    fail)
      verdict Q3 BUDGET-EXCEEDS-CAP "cmux's ${BUDGET_BYTES}B budget does not survive this transport: the start marker ran and the end marker did not, so the line was cut and a full-length cmux attach would silently deliver nothing"
      return;;
  esac
  q3_probe over "$OVER_BYTES" \
    "confirm a cut is detectable here: a deliberately over-limit ${OVER_BYTES}B command must NOT arrive whole"
  case "$PROBE_RESULT" in
    fail)
      verdict Q3 BUDGET-FITS "a ${BUDGET_BYTES}B command (cmux's own budget) arrived whole while a ${OVER_BYTES}B one was cut, so the limit is real on this host and cmux's budget sits under it";;
    pass)
      verdict Q3 NO-CAP-OBSERVED "the ${BUDGET_BYTES}B budget arrived whole and so did ${OVER_BYTES}B: the budget is safe here, but this run did not find the edge (raise OVER_BYTES to look further)";;
    *)
      verdict Q3 BUDGET-FITS-UNCONFIRMED "the ${BUDGET_BYTES}B budget arrived whole; the over-limit probe was not measured (${PROBE_DETAIL}), so the cut detector was not exercised against the real host";;
  esac
}

# ---------- checks 4 + 5 + 7: cmux's control-stream command over the broker ----------
# cmux's order: a one-shot creates the session, then the control client joins it as a grouped
# session, which is what gives a mirror its own current window. cmux spends two connections on
# that and the harness spends one, so this does NOT cover a host that reaps detached sessions at
# logout between cmux's two connections. Creation is proved before anything is graded: without
# that, a stale session of the same name would answer for all three checks.
SESS=""; SESS_CREATED=no
q457_run() {
  next_marker
  SESS="cmuxh${RUNID}"
  local rcmd before hoff created
  rcmd="$(marker_prefix)$(login_probe_command); "
  rcmd="${rcmd}tmux new-session -d -s ${SESS} || { echo K\$v=failed; exit 1; }; echo K\$v=created; "
  # The verb the PRODUCT sends, not a friendlier one. cmux uses `attach-session` for a session that
  # already exists; this harness always sent the grouped `new-session -t` form, so the one command
  # that mattered was never tested — and the harness passed on a host where the app's mirror came up
  # empty. CONTROL_VERB exists to compare them, and defaults to what ships.
  rcmd="${rcmd}exec 'tmux' '-CC' '${CONTROL_VERB}' '-t' '${SESS}'"
  check_banner "cmux's own login probe and control-stream command over the broker (session ${SESS})"
  launch_conn cc "$rcmd"
  if ! wait_delivery "$MK" "checks 4-7: command delivery"; then
    local d; d="$(delivery_failure_detail)"
    want 1 && verdict Q1 INCONCLUSIVE "$d"
    want 2 && verdict Q2 INCONCLUSIVE "cannot measure: nothing was delivered"
    want 4 && verdict Q4 INCONCLUSIVE "$d, so nothing can be said about control mode"
    want 5 && verdict Q5 INCONCLUSIVE "no handshake bytes to locate"
    want 7 && verdict Q7 INCONCLUSIVE "no control stream to exercise"
    close_or_abort; return
  fi
  if wait_marker "L${MV}=(yes|no) T${MV}=[^ ]+" "$OP_TIMEOUT" "checks 1-2: probe result" >/dev/null; then
    grade_login
  else
    want 1 && verdict Q1 FAIL "the command reached the remote shell but the login probe produced no result line"
    want 2 && verdict Q2 INCONCLUSIVE "cannot measure: the probe produced no result"
  fi
  # Ownership is recorded only once creation is confirmed, so a leftover state file always names
  # a session this run really made.
  if wait_marker "K${MV}=(created|failed)" "$OP_TIMEOUT" "checks 4-7: session creation" >/dev/null; then
    created=$(marker_value "K${MV}")
  else
    created=unknown
  fi
  if [ "$created" != created ]; then
    want 4 && verdict Q4 INCONCLUSIVE "the one-shot did not create ${SESS} (result: ${created}); the control client was never started, so control mode was not measured. A name collision reports this rather than attaching to a session this run does not own."
    want 5 && verdict Q5 INCONCLUSIVE "no handshake bytes to locate"
    want 7 && verdict Q7 INCONCLUSIVE "no control stream to exercise"
    close_or_abort; return
  fi
  SESS_CREATED=yes
  printf 'HOST=%s\nSESS=%s\nRUNID=%s\nSTATUS=created\n' "$HOST" "$SESS" "$RUNID" > "$WORKDIR/state"
  if hoff=$(wait_bytes "$CONN_LOG" '\x1bP1000p' "$OP_TIMEOUT" 0 "checks 4-7: ESC P 1000 p handshake"); then
    # A handshake plus a complete block is NOT evidence of a usable mirror, and this check used to
    # stop there. Measured on a real host: the failing stream sent the DCS intro, a complete
    # %begin/%end pair, %session-changed, and then %exit — no window ever arrived. That satisfied
    # the old criterion, so this check passed while the app it stands in for came up empty. So a
    # pass now needs the block AND a live stream AND something to mirror.
    if ! wait_block "$CONN_LOG" "$hoff" "$OP_TIMEOUT" "" "checks 4-7: a complete %begin/%end block" >/dev/null; then
      want 4 && verdict Q4 FAIL "the DCS intro arrived but no complete %begin/%end block followed within ${OP_TIMEOUT}s"
    elif grep -a -q '%exit' "$CONN_LOG"; then
      want 4 && verdict Q4 FAIL "control mode was reached and then the stream sent %exit before any window arrived: the client exited on its own, so there is nothing to mirror. This is the shape a mirror-comes-up-empty bug takes on the wire (raw log: ${CONN_LOG})"
    else
      want 4 && verdict Q4 PASS "cmux's exact control-stream command reached control mode through the broker and stayed alive: ESC P 1000 p at byte ${hoff}, a complete %begin/%end block, no %exit (raw log: ${CONN_LOG})"
    fi
    # This check used to also require an unsolicited window notification, and that was wrong.
    # Measured against tmux directly (`tmux -CC attach-session -t <live session>` under a pty): the
    # whole stream is 84 bytes — the DCS intro, one %begin/%end pair, and %session-changed. No
    # %window-add, no %windows-changed, no %layout-change. Attaching to an existing session
    # announces nothing, because there is no change to announce; cmux learns the topology by
    # SENDING list-windows and reading the reply, which is what check 7 below exercises.
    #
    # The false requirement survived 50 selftest assertions because the fake emitted %window-add on
    # attach, so no scenario ever reached that branch — the stand-in was looser than reality in
    # exactly the direction that hides a broken oracle. The fake no longer emits it.
    want 5 && q5_classify "$CONN_LOG"
    before=$(wc -c < "$CONN_LOG")
    if pane_send_live "list-windows" "list-windows"; then
      # One complete block that contains a window line, found after the request was sent. Any
      # %end and a stray "N panes" in asynchronous output would satisfy two separate matches.
      if wait_block "$CONN_LOG" "$before" "$OP_TIMEOUT" '[0-9]+ panes' "check 7: the list-windows reply block" >/dev/null; then
        want 7 && verdict Q7 PASS "the grouped session answered list-windows inside one complete %begin/%end block, so cmux's RPCs work over this transport and not only its handshake"
      else
        want 7 && verdict Q7 FAIL "the control stream did not answer list-windows with a complete block within ${OP_TIMEOUT}s"
      fi
    else
      want 7 && verdict Q7 INCONCLUSIVE "the connection closed before list-windows could be sent"
    fi
    # An observation, not a pass or fail. et appends its own `exit` to the line it types, and
    # because cmux's command execs tmux, that word arrives on the control stream as a command.
    # tmux answers with a block carrying an id cmux never issued, so cmux's parser has to
    # tolerate an unsolicited error block here. The substitute broker cannot reproduce this, so
    # it is only ever observed on a real run.
    if grep -a -q "unknown command: exit" "$CONN_LOG"; then
      verdict Q8 OBSERVED "the transport's trailing exit reached tmux as a control command and tmux replied with an error block whose id cmux never issued, so cmux's parser must ignore unsolicited error blocks here (evidence in ${CONN_LOG})"
    else
      verdict Q8 NOT-SEEN "no stray exit reached the control stream on this run"
    fi
    pane_send_live "detach-client" "detach-client" || true
  else
    local extra=""
    grep -a -q "command not found" "$CONN_LOG" && extra="; the log shows 'command not found', so a bare tmux did not resolve"
    grep -a -q "can.t find session" "$CONN_LOG" && extra="${extra}; the log shows tmux could not find the session the one-shot created"
    want 4 && verdict Q4 FAIL "the command was delivered and the session was created, but no ESC P 1000 p handshake arrived within ${OP_TIMEOUT}s${extra}; a silent live process cannot be told from a dead one, so this counts as not reaching control mode"
    want 5 && verdict Q5 INCONCLUSIVE "no handshake bytes to locate"
    want 7 && verdict Q7 INCONCLUSIVE "no control stream to exercise"
  fi
  close_or_abort
}

q5_classify() { # where the handshake sits in the raw stream: cmux's parser has to find it there
  python3 - "$1" <<'PY' | tee -a "$VERDICT_FILE"
import sys
data = open(sys.argv[1], 'rb').read()
i = data.find(b'\x1bP1000p')
if i < 0:
    print("VERDICT Q5: INCONCLUSIVE | handshake bytes not found in the raw log")
    raise SystemExit
prev = data[max(0, i-1):i]
ctx = data[max(0, i-32):i+16]
sol = (i == 0) or prev in (b'\n', b'\r')
kind = 'START-OF-LINE' if sol else 'MID-LINE'
print("VERDICT Q5: %s | ESC P 1000 p begins at byte %d; preceding byte %r; context %r" % (kind, i, prev, ctx))
PY
}

# ---------- check 6 + cleanup: does the session outlive its client? ----------
# cmux treats end-of-stream on this transport as "reconnect" rather than "session gone", so
# survival is load-bearing. Two details decide whether the answer means anything:
#
#   has-session -t NAME matches by prefix, so once tmux has auto-named the grouped sibling
#   NAME-8, a dead base session still answers yes through its sibling. The query uses =NAME.
#
#   Cleanup reports success only after a listing proves nothing matching this run is left. A
#   kill that failed while the marker still said done wrote STATUS=cleaned over the only pointer
#   to a leftover session.
q6_run() {
  next_marker
  local rcmd alive left
  if [ "$SESS_CREATED" != yes ]; then
    verdict Q6 INCONCLUSIVE "no session was created this run, so survival was never measurable"
    return
  fi
  rcmd="$(marker_prefix)tmux has-session -t \"=${SESS}\" 2>/dev/null && echo A\$v=yes || echo A\$v=no; "
  rcmd="${rcmd}for s in \$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^${SESS}(\$|-)'); do tmux kill-session -t \"=\$s\"; done; "
  rcmd="${rcmd}echo C\$v=\$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -cE '^${SESS}(\$|-)')"
  check_banner "did session ${SESS} outlive its client? (then remove this run's sessions)"
  launch_conn q6 "$rcmd"
  if ! wait_delivery "$MK" "check 6: delivery"; then
    verdict Q6 INCONCLUSIVE "$(delivery_failure_detail); ${SESS} may still exist on ${HOST}: run '$SELF cleanup'"
    close_or_abort; return
  fi
  if ! wait_marker "A${MV}=(yes|no)" "$OP_TIMEOUT" "check 6: survival result" >/dev/null; then
    verdict Q6 INCONCLUSIVE "the command reached the shell but produced no survival result; ${SESS} may still exist: run '$SELF cleanup'"
    close_or_abort; return
  fi
  alive=$(marker_value "A${MV}")
  if [ "$alive" = yes ]; then
    verdict Q6 PASS "session ${SESS} was still there on a later connection (has-session -t =${SESS}, an exact match rather than a prefix that its grouped sibling would also satisfy), so cmux is right to treat end-of-stream here as reconnect rather than session-gone"
  else
    verdict Q6 FAIL "session ${SESS} was gone on a later connection: it died with its client, so end-of-stream means the session is gone and cmux's reconnect assumption does not hold here"
  fi
  if wait_marker "C${MV}=[0-9]+" "$OP_TIMEOUT" "check 6: cleanup count" >/dev/null; then
    left=$(marker_value "C${MV}")
    if [ "$left" = 0 ]; then
      printf 'HOST=%s\nSESS=%s\nRUNID=%s\nSTATUS=cleaned\n' "$HOST" "$SESS" "$RUNID" > "$WORKDIR/state"
      note "cleanup verified: no session matching ${SESS} is left on the host"
    else
      note "ATTENTION: ${left} session(s) matching ${SESS} still exist after cleanup; state kept so '$SELF cleanup' can retry"
    fi
  else
    note "ATTENTION: no cleanup count came back; run '$SELF cleanup' to retry"
  fi
  close_or_abort
}

# ---------- run mode ----------
cmd_run() {
  validate_ids
  [ -n "$HOST" ] || die "HOST is required for a real run (e.g. HOST=mybox $SELF run)"
  [ -n "$PANE" ] || die "PANE is required for a real run (e.g. PANE=0:0.0); the harness types into it"
  # Named rather than defaulted: which wrapper reaches a host is a property of the network you are
  # on, not of this harness, and a guessed path would fail as "connection refused" somewhere deep
  # instead of here.
  [ -n "$BROKER" ] || die "BROKER is required for a real run (the wrapper that reaches the host, e.g. BROKER=/usr/local/bin/mybroker); set BROKER_ARGS for the flags it takes before the destination"
  [ -x "$BROKER" ] || die "BROKER is not executable: $BROKER"
  [ -n "$TMUX_BIN" ] || die "tmux not found"
  command -v python3 >/dev/null || die "python3 not found"
  workdir_init
  : > "$VERDICT_FILE"
  tm display-message -p -t "$PANE" '#{pane_id}' >/dev/null 2>&1 || die "pane '$PANE' not found (set PANE=session:window.pane)"
  # The harness types into this pane, so it has to be sitting at a shell. Typing a banner into
  # a full-screen program sends keystrokes to that program instead.
  local pcmd; pcmd=$(tm display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null)
  case "$pcmd" in
    sh|bash|zsh|fish|dash|ksh|tcsh|csh) ;;
    *) die "pane '$PANE' is running '$pcmd', not a shell; the harness would type into it. Use an idle shell pane.";;
  esac

  # State the human cost up front and what each touch buys. Checks share a connection where one
  # command can answer several questions, because a touch is the scarcest thing here.
  local n=0 plan="" folded=0
  if want 4 || want 5 || want 7; then folded=1; fi
  if { want 1 || want 2; } && [ "$folded" = 0 ]; then
    n=$((n+1)); plan="${plan}  touch ${n}: -c reaches a login shell that resolves tmux\n"
  fi
  if want 3; then
    n=$((n+1)); plan="${plan}  touch ${n}: a ${BUDGET_BYTES}B command (cmux's budget) arrives whole\n"
    n=$((n+1)); plan="${plan}  touch ${n}: a ${OVER_BYTES}B command does not, so a cut is detectable here\n"
  fi
  if [ "$folded" = 1 ]; then
    n=$((n+1)); plan="${plan}  touch ${n}: login shell, tmux on PATH, and cmux's own tmux -CC command reaching control mode and answering an RPC, on one connection\n"
  fi
  if want 6; then n=$((n+1)); plan="${plan}  touch ${n}: the session outlived its client, then cleanup\n"; fi
  TAP_TOTAL=$n
  note "run ${RUNID}; host ${HOST}; broker ${BROKER} ${BROKER_ARGS}; pane ${PANE}; checks: ${QUESTIONS}"
  note "${n} security-key touches, one per connection:"
  printf '%b' "$plan"
  pane_banner "run ${RUNID}: ${n} security-key touches expected, one per check"

  # q457_run answers checks 1 and 2 too, on the shell that actually runs cmux's command, so the
  # standalone probe runs only when no control-stream check was asked for.
  if { want 1 || want 2; } && [ "$folded" = 0 ]; then q12_run; fi
  if want 3; then q3_run; fi
  if want 4 || want 5 || want 6 || want 7; then q457_run; fi
  if want 6; then
    q6_run
  elif [ "$SESS_CREATED" = yes ]; then
    note "ATTENTION: session ${SESS} was created but check 6 was not requested, so nothing removed it; run '$SELF cleanup'"
  fi

  say ""
  say "==== SUMMARY (run ${RUNID}) ===="
  sed 's/^/  /' "$VERDICT_FILE" 2>/dev/null
}

cmd_cleanup() {
  validate_ids
  workdir_init
  [ -n "$PANE" ] || die "PANE is required (e.g. PANE=0:0.0)"
  [ -f "$WORKDIR/state" ] || die "no state file at $WORKDIR/state; nothing to clean"
  : > "$VERDICT_FILE"
  local shost ssess sstat
  shost=$(sed -n 's/^HOST=//p' "$WORKDIR/state")
  ssess=$(sed -n 's/^SESS=//p' "$WORKDIR/state")
  sstat=$(sed -n 's/^STATUS=//p' "$WORKDIR/state")
  [ "$sstat" = cleaned ] && { note "state says ${ssess} was already removed and verified"; return 0; }
  [ -n "$ssess" ] || die "state file has no session name"
  case "$ssess" in *[!A-Za-z0-9_-]*) die "state file session name is not safe to send: $ssess";; esac
  HOST="$shost"
  next_marker
  local rcmd left
  rcmd="$(marker_prefix)for s in \$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^${ssess}(\$|-)'); do tmux kill-session -t \"=\$s\"; done; "
  rcmd="${rcmd}echo C\$v=\$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -cE '^${ssess}(\$|-)')"
  TAP_TOTAL=1
  note "one connection (one key touch) to remove sessions matching ${ssess} on ${shost}"
  check_banner "cleanup: removing leftover harness sessions matching ${ssess}"
  launch_conn clean "$rcmd"
  # The same two budgets a check gets: auth is the human's, delivery is the broker's.
  if ! wait_delivery "$MK" "cleanup: delivery"; then
    note "ATTENTION: $(delivery_failure_detail); ${ssess} may still exist on ${shost}"
    close_conn; return 1
  fi
  if wait_marker "C${MV}=[0-9]+" "$OP_TIMEOUT" "cleanup count" >/dev/null; then
    left=$(marker_value "C${MV}")
    if [ "$left" = 0 ]; then
      printf 'HOST=%s\nSESS=%s\nSTATUS=cleaned\n' "$shost" "$ssess" > "$WORKDIR/state"
      note "cleanup verified: nothing matching ${ssess} is left on ${shost}"
    else
      note "ATTENTION: ${left} session(s) matching ${ssess} remain; state kept so this can be retried"
    fi
  else
    note "ATTENTION: no cleanup count came back; ${ssess} may still exist on ${shost}"
  fi
  close_conn
}

# ---------- the substitute broker (selftest) ----------
# Emulates the broker's argument grammar, et's need for a pty, et typing '<cmd>; exit' into a
# remote login zsh, a delivery cap that truncates the typed line, and a remote tmux that groups
# sessions in -CC mode. Mutants are chosen with FAKE_* variables so each verdict can be shown
# to move both ways.
#
# The echo is deliberately NOT truncated with delivery. A real transport echoes the whole line
# it typed even when the shell only received part of it, so a substitute that truncates both is
# easier than reality — and it made the harness structurally unable to notice that its success
# needles could be matched in the echo.
fake_read_until_exit() {
  local l
  while IFS= read -r l; do
    l=${l%$'\r'}
    [ "$l" = exit ] && return 0
  done
  return 0
}

fake_write_shim() { # $1 = state dir
  mkdir -p "$1/bin" "$1/zdot"
  cat > "$1/bin/tmux" <<'SHIM'
#!/bin/bash
# substitute remote tmux (selftest shim). State = files in $FAKE_STATE.
# Argument handling is strict on purpose: a shim that accepts argv the real tool rejects lets
# the harness pass with a command real tmux would refuse.
state="${FAKE_STATE:?}"
cc=0 det=0 cmdname="" name="" exact=0 fmt=""
args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    -CC) cc=1;;
    -d) det=1;;
    new-session|attach-session|has-session|kill-session|list-sessions) cmdname=$1;;
    -s|-t)
      shift
      name=${1:-}
      case "$name" in "="*) exact=1; name=${name#=};; esac;;
    -F) shift; fmt=${1:-};;
    *) echo "shim: unexpected argument: $1" >&2; exit 1;;
  esac
  shift
done

# Real tmux resolves a target name by prefix unless it is given as =NAME. Emulating that is the
# point: without it, a check that queries by prefix cannot be shown to answer for the wrong
# session.
resolve() { # <name> -> prints matching session names
  local n="$1" f b
  for f in "$state"/session_*; do
    [ -e "$f" ] || continue
    b=$(basename "$f" | sed 's/^session_//')
    if [ "$exact" = 1 ]; then
      [ "$b" = "$n" ] && printf '%s\n' "$b"
    else
      case "$b" in "$n"*) printf '%s\n' "$b";; esac
    fi
  done
}

case "$cmdname" in
  list-sessions)
    [ -n "$fmt" ] || { echo "shim: list-sessions needs -F" >&2; exit 1; }
    for f in "$state"/session_*; do
      [ -e "$f" ] || continue
      basename "$f" | sed 's/^session_//'
    done
    exit 0;;
  has-session)
    [ -n "$name" ] || { echo "shim: has-session needs -t" >&2; exit 1; }
    [ -n "$(resolve "$name")" ]; exit $?;;
  kill-session)
    [ -n "$name" ] || { echo "shim: kill-session needs -t" >&2; exit 1; }
    local_hit=$(resolve "$name")
    [ -n "$local_hit" ] || { echo "can't find session: $name" >&2; exit 1; }
    for s in $local_hit; do rm -f "$state/session_$s"; done
    exit 0;;
  attach-session|new-session)
    # Both verbs share ONE emission body. They used to have separate ones, and when the default verb
    # changed every mutant that lived in only one branch silently stopped being exercised — the same
    # class of gap that let this harness pass while the app was broken.
    if [ "$cmdname" = new-session ] && [ "$cc" = 0 ]; then
      # the detached one-shot cmux runs first
      [ "$det" = 1 ] || { echo "shim: expected -d for a detached create" >&2; exit 1; }
      [ -n "$name" ] || { echo "shim: new-session -d needs -s" >&2; exit 1; }
      if [ -f "$state/session_$name" ] || [ "${FAKE_DUP_SESSION:-0}" = 1 ]; then
        echo "duplicate session: $name" >&2
        exit 1
      fi
      touch "$state/session_$name"
      exit 0
    fi
    # Real tmux refuses either verb when the target is missing, so the shim must too, or the
    # selftest would pass on an ordering the real host rejects.
    if [ ! -f "$state/session_$name" ]; then
      echo "can't find session: $name" >&2
      exit 1
    fi
    if [ "$cmdname" = new-session ]; then
      # grouped: tmux makes a second session sharing the windows and reports THAT name
      touch "$state/session_${name}-8"
      reported="${name}-8"; sess_id='$8'
    else
      reported="$name"; sess_id='$0'
    fi
    if [ "${FAKE_NO_CC:-0}" = 1 ]; then
      # spawned but silent: looks identical to a working process
      while IFS= read -t 60 -r l; do
        l=${l%$'\r'}
        case "$l" in detach-client|exit) exit 0;; esac
      done
      exit 0
    fi
    if [ "${FAKE_HANDSHAKE:-startline}" = midline ]; then
      printf 'Last login: Mon Jul 21 10:00:00 on ttys000\r\nmotd: welcome '
    fi
    printf '\033P1000p'
    if [ "${FAKE_PARTIAL_BLOCK:-0}" = 1 ]; then
      # a %begin with no matching %end, then silence
      printf '%%begin 1000 1 0\r\n'
      sleep 120
      exit 0
    fi
    printf '%%begin 1000 1 0\r\n%%end 1000 1 0\r\n'
    printf '%%session-changed %s %s\r\n' "$sess_id" "$reported"
    if [ "${FAKE_EXIT_BEFORE_WINDOW:-0}" = 1 ]; then
      # The exact failing shape measured on a real host: control mode reached, the attach block
      # completed, the session reported — then the client exits before announcing any window. A
      # check that stops at "handshake plus a complete block" calls this a pass.
      printf '%%exit\r\n\033\\'
      exit 0
    fi
    # No %window-add here, deliberately. Real tmux announces nothing when a control client attaches
    # to an existing session — measured, the whole attach is 84 bytes — and a stand-in that is more
    # talkative than the real thing hid a broken oracle in check 4 for a whole run of the selftest.
    # Set FAKE_ANNOUNCES_WINDOW=1 to get the old, unrealistic behaviour back for a specific test.
    if [ "${FAKE_ANNOUNCES_WINDOW:-0}" = 1 ]; then
      printf '%%window-add @1\r\n'
    fi
    if [ "${FAKE_ASYNC_PANES:-0}" = 1 ]; then
      # pane output that happens to contain the words a loose check looks for, plus an unrelated
      # completed block, but no answer to list-windows
      printf '%%output %%9 window has 3 panes now\r\n'
      printf '%%begin 999 9 0\r\n%%end 999 9 0\r\n'
    fi
    while IFS= read -t 120 -r l; do
      l=${l%$'\r'}
      case "$l" in
        list-windows)
          [ "${FAKE_NO_LISTWINDOWS:-0}" = 1 ] && continue
          if [ "${FAKE_ASYNC_PANES:-0}" = 1 ]; then continue; fi
          printf '%%begin 1001 2 1\r\n0: zsh* (1 panes) [200x50] [layout b25d,200x50,0,0,1] @1 (active)\r\n%%end 1001 2 1\r\n';;
        detach-client)
          printf '%%exit\r\n\033\\'
          if [ "${FAKE_SIBLING_ONLY:-0}" = 1 ]; then
            # the base dies with the client but its grouped sibling lives on: a prefix query would
            # still call that survival
            rm -f "$state/session_$name"
          elif [ "${FAKE_SURVIVES:-1}" != 1 ]; then
            rm -f "$state/session_$name" "$state/session_${name}-8"
          fi
          exit 0;;
        exit) exit 0;;
      esac
    done
    exit 0;;
  *) echo "shim: unhandled tmux invocation: ${args[*]}" >&2; exit 1;;
esac
SHIM
  chmod +x "$1/bin/tmux"
}

fake_run_cmd() { # $1 = command string; run it the way et's remote login zsh would
  local state="${FAKE_STATE:?}" zl="-l"
  [ "${FAKE_NONLOGIN:-0}" = 1 ] && zl=""
  local path="$state/bin:$PATH"
  [ "${FAKE_NO_TMUX:-0}" = 1 ] && path="$state/emptybin"
  mkdir -p "$state/emptybin" "$state/tmuxguard"
  # ZDOTDIR keeps real zsh dotfiles out of the selftest. .zshenv (sourced by every zsh) makes
  # sure a real tmux reached by accident cannot touch any real server.
  {
    printf 'unset TMUX TMUX_PANE\n'
    printf 'export TMUX_TMPDIR=%q\n' "$state/tmuxguard"
  } > "$state/zdot/.zshenv"
  # .zprofile runs after /etc/zprofile, whose path_helper prepends system dirs (including the
  # real tmux) ahead of the shim, so re-assert the intended PATH last.
  if [ "${FAKE_NO_TMUX:-0}" = 1 ]; then
    printf 'path=(%q /usr/bin /bin)\n' "$state/emptybin" > "$state/zdot/.zprofile"
  else
    printf 'path=(%q $path)\n' "$state/bin" > "$state/zdot/.zprofile"
  fi
  if [ -n "$zl" ]; then
    ZDOTDIR="$state/zdot" PATH="$path" FAKE_STATE="$state" /bin/zsh -l -c "$1"
  else
    ZDOTDIR="$state/zdot" PATH="$path" FAKE_STATE="$state" /bin/zsh -c "$1"
  fi
}

# Echo the typed line the way an interactive zsh does, optionally with the redraw noise a real
# one produces when the line is longer than the terminal is wide. That noise puts a bare CR
# immediately before a row's first character, which is how an echo can end up satisfying a
# needle anchored only to a preceding newline.
fake_echo_typed() {
  local typed="$1" width=180 i=0 n=${#typed}
  if [ "${FAKE_REDRAW:-0}" != 1 ]; then
    printf 'fakehost%% %s\r\n' "$typed"
    return
  fi
  printf 'fakehost%% '
  while [ "$i" -lt "$n" ]; do
    printf '%s' "${typed:$i:$width}"
    i=$((i + width))
    [ "$i" -lt "$n" ] && printf ' \r\033[K'
  done
  printf '\r\n'
}

fake_main() {
  local et=0 fb=0 tf=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -et) et=1; shift;;
      -terminal_feedback) tf=1; shift;;
      -fallback) fb=1; shift;;
      -c) break;;
      -*) echo "fake-broker: flag provided but not defined: $1" >&2; exit 2;;
      *) break;;
    esac
  done
  [ $# -ge 1 ] || { echo "fake-broker: missing hostname" >&2; exit 64; }
  # The real broker needs -et to use the et transport at all; accepting its absence would let
  # the harness pass with argv the real one rejects.
  if [ "${FAKE_REQUIRE_ET:-1}" = 1 ]; then
    [ "$et" = 1 ] || { echo "fake-broker: -et is required" >&2; exit 64; }
  fi
  local host cmd
  if [ "${1:-}" = "-c" ]; then
    # direct order: -c <command> <destination>
    [ $# -eq 3 ] || { echo "fake-broker: expected -c <command> <destination>, got: $*" >&2; exit 64; }
    cmd="$2"; host="$3"
  else
    # brokered order: <destination> -c <command>
    host="$1"; shift
    [ "${1:-}" = "-c" ] || { echo "fake-broker: expected -c after hostname, got: $*" >&2; exit 64; }
    [ $# -eq 2 ] || { echo "fake-broker: unexpected trailing arguments: $*" >&2; exit 64; }
    cmd="$2"
  fi
  # et with plain-pipe stdio produces nothing at all, so any wrapper that captures stdout or
  # stdin fails the selftest here rather than on a real host.
  if [ "${FAKE_PTY_STRICT:-1}" = 1 ]; then
    [ -t 0 ] && [ -t 1 ] || exit 0
  fi
  echo "broker(fake): connecting to ${host} (et=${et} fallback=${fb} tf=${tf})"
  echo "broker(fake): please touch your security key to authorize this connection..."
  if [ "${FAKE_HANG:-0}" = 1 ]; then
    exec sleep 100000
  fi
  if [ "${FAKE_OTP:-1}" = 1 ]; then
    printf 'Enter a passcode:\r\n'
    if [ "${FAKE_REJECT_ONCE:-0}" = 1 ]; then
      printf 'Passcode: fakeotpaaaaaaaaaaaaaaaaaaaa\r\n'
      printf 'Incorrect passcode. Please try again.\r\n'
      printf 'Enter a passcode:\r\n'
      sleep 1
    fi
    printf 'Passcode: fakeotpbbbbbbbbbbbbbbbbbbbb\r\n'
  fi
  if [ "${FAKE_STALL_AFTER_AUTH:-0}" = 1 ]; then
    exec sleep 100000
  fi
  echo "broker(fake): authorized."
  local state="${FAKE_STATE:?FAKE_STATE dir required}"
  fake_write_shim "$state"
  # et types '<cmd>; exit' into the remote shell. The delivery path caps what the shell receives
  # while the echo still shows the whole line.
  local typed="${cmd}; exit" lim="${FAKE_LIMIT:-4095}" delivered
  delivered=${typed:0:lim}
  fake_echo_typed "$typed"
  if [ "${FAKE_NO_EXEC:-0}" = 1 ]; then
    fake_read_until_exit; exit 0
  fi
  # A real interactive zsh sets the tmux window title before it runs the line, so command output
  # arrives right after "ESC k <title> ST" and the byte before it is a printable backslash.
  [ "${FAKE_TITLE:-1}" = 1 ] && printf '\033kecho\033\\'
  if [ "$delivered" = "$typed" ]; then
    fake_run_cmd "$cmd"
    exit 0
  else
    printf '\a'   # a real line limit beeps
    # Measured against real et on a canonical-mode pty: the excess bytes AND the terminating
    # newline are lost together, so the shell runs nothing until a newline arrives, and whatever
    # is typed next is glued onto the partial line. A substitute that runs the truncated command
    # immediately is easier than reality, and it hid the harness's dependence on that newline.
    local extra=""
    IFS= read -r extra || true
    extra=${extra%$'\r'}
    [ "${FAKE_TITLE:-1}" = 1 ] && printf '\033kecho\033\\'
    fake_run_cmd "${delivered}${extra}" 2>&1 || true
    # the '; exit' was cut away, so the shell is now at a prompt until told to exit
    fake_read_until_exit
    exit 0
  fi
}

# ---------- selftest ----------
ST_ROOT=""; ST_PANE=""; ST_DIR=""; ST_PASS=0; ST_FAIL=0; ST_RC=0

# Needles include the field separator: without it, "VERDICT Q3: BUDGET-FITS" is satisfied by
# "BUDGET-FITS-UNCONFIRMED", and the selftest reports a detector proven that never fired.
expect() { # <scenario> <needle>
  if grep -F -q "$2" "$ST_ROOT/$1/out" 2>/dev/null; then
    say "SELFTEST PASS: [$1] found: $2"; ST_PASS=$((ST_PASS+1))
  else
    say "SELFTEST FAIL: [$1] missing: $2"; ST_FAIL=$((ST_FAIL+1))
  fi
}
expect_absent() { # <scenario> <needle that must NOT appear>
  if grep -F -q "$2" "$ST_ROOT/$1/out" 2>/dev/null; then
    say "SELFTEST FAIL: [$1] present but must not be: $2"; ST_FAIL=$((ST_FAIL+1))
  else
    say "SELFTEST PASS: [$1] absent as required: $2"; ST_PASS=$((ST_PASS+1))
  fi
}
expect_verdict() { expect "$1" "VERDICT $2: $3 |"; }

run_scenario() { # <name> <questions> <fake-env-list> [harness-env-list]
  local name=$1 qs=$2 fenv=$3 henv=${4:-} wd fake kv
  wd="$ST_ROOT/$name"; mkdir -p "$wd/fakestate"
  fake="$wd/fake-broker"
  if ! tm display-message -p -t "$ST_PANE" '#{pane_id}' >/dev/null 2>&1; then
    note "selftest pane is gone; recreating it"
    tm -f /dev/null new-session -d -s cmuxharness -x 220 -y 50 '/bin/bash --norc'
  fi
  {
    echo '#!/bin/bash'
    echo "export FAKE_STATE='$wd/fakestate'"
    for kv in $fenv; do echo "export $kv"; done
    echo "exec '$SELF' _fake \"\$@\""
  } > "$fake"
  chmod +x "$fake"
  tm clear-history -t "$ST_PANE" 2>/dev/null
  note "scenario ${name}: QUESTIONS='${qs}' fake: ${fenv} ${henv:+harness: $henv}"
  (
    export PANE="$ST_PANE" BROKER="$fake" HOST=fakehost WORKDIR="$wd" TM_SOCKET="$TM_SOCKET" \
      RUNID="st${name}" QUESTIONS="$qs" AUTH_TIMEOUT=20 CONNECT_TIMEOUT=8 OP_TIMEOUT=5 \
      SEED_BASE=1000000 TMUX_BIN="$TMUX_BIN"
    for kv in $henv; do export "$kv"; done
    "$SELF" run
  ) > "$wd/out" 2>&1
  ST_RC=$?
  sed -n 's/^VERDICT /  VERDICT /p' "$wd/out"
}

# A scenario that prints the right verdict and then dies still tells us the harness is broken.
expect_rc() { # <scenario> <expected-rc>
  if [ "$ST_RC" = "$2" ]; then
    say "SELFTEST PASS: [$1] exit status $2"; ST_PASS=$((ST_PASS+1))
  else
    say "SELFTEST FAIL: [$1] exit status $ST_RC, expected $2"; ST_FAIL=$((ST_FAIL+1))
  fi
}

cmd_selftest() {
  command -v python3 >/dev/null || die "python3 not found"
  [ -n "$TMUX_BIN" ] || die "tmux not found"
  workdir_init
  ST_ROOT="$WORKDIR/selftest"
  rm -rf "$ST_ROOT"; mkdir -p "$ST_ROOT"
  # A private directory and an explicit socket path, so no inherited TMUX_TMPDIR and no
  # fallback can put these tmux calls on the user's default server.
  ST_DIR=$(mktemp -d "/tmp/cmux-harness-st.XXXXXX") || die "mktemp failed"
  TM_SOCKET="$ST_DIR/sock"
  case "$TM_SOCKET" in
    "/tmp/tmux-$(id -u)"/*) die "refusing a socket under the default tmux socket dir";;
  esac
  unset TMUX
  # Create the server first, then install the trap that can kill it, so a failure in between
  # cannot leave an orphan server behind with nothing to reap it.
  tm -f /dev/null new-session -d -s cmuxharness -x 220 -y 50 '/bin/bash --norc' \
    || { rm -rf "$ST_DIR"; die "could not start the private tmux server"; }
  trap 'tm kill-server 2>/dev/null; rm -rf "$ST_DIR"' EXIT
  local sock; sock=$(tm display-message -p '#{socket_path}')
  case "$sock" in
    "$TM_SOCKET"|/private"$TM_SOCKET") ;;
    *) die "socket check failed: server is on $sock, not $TM_SOCKET";;
  esac
  ST_PANE="cmuxharness:0.0"
  note "selftest: private tmux server on $sock, pane $ST_PANE"

  # Known-good substitute: cap 4095 bytes, so cmux's 928-byte budget fits and 4200 does not.
  run_scenario good "1 2 3 4 5 6 7" "FAKE_LIMIT=4095"
  expect_verdict good Q1 PASS
  expect_verdict good Q2 PASS
  expect_verdict good Q3 BUDGET-FITS
  expect_verdict good Q4 PASS
  expect_verdict good Q5 START-OF-LINE
  expect_verdict good Q6 PASS
  expect_verdict good Q7 PASS
  expect_rc good 0

  # Typed but never executed: check 1 must FAIL and check 2 must become unmeasurable.
  run_scenario q1fail "1 2" "FAKE_NO_EXEC=1"
  expect_verdict q1fail Q1 FAIL
  expect_verdict q1fail Q2 INCONCLUSIVE

  # A non-login shell with no tmux: check 2 must FAIL while check 1 still passes.
  run_scenario q2fail "1 2" "FAKE_NONLOGIN=1 FAKE_NO_TMUX=1"
  expect_verdict q2fail Q1 PASS
  expect_verdict q2fail Q2 FAIL

  # A cap below cmux's budget.
  run_scenario q3tiny "3" "FAKE_LIMIT=500"
  expect_verdict q3tiny Q3 BUDGET-EXCEEDS-CAP

  # No cap in range: say the edge was never found rather than claiming one was measured.
  run_scenario q3open "3" "FAKE_LIMIT=999999"
  expect_verdict q3open Q3 NO-CAP-OBSERVED

  # Everything delivered but nothing executed. Absence of the end marker must NOT be read as a
  # cut: without the start marker this reported a length limit that does not exist.
  run_scenario q3noexec "3" "FAKE_LIMIT=999999 FAKE_NO_EXEC=1"
  expect_verdict q3noexec Q3 INCONCLUSIVE
  # The wording matters as much as the verdict: this case must say the command never reached a
  # shell, not that a length limit was found.
  expect q3noexec "never reached a shell"

  # A cut line whose echo is redrawn: the echo contains the end marker with a bare CR in front
  # of it, so a needle anchored only to a preceding newline would call this delivered.
  run_scenario q3redraw "3" "FAKE_LIMIT=500 FAKE_REDRAW=1"
  expect_verdict q3redraw Q3 BUDGET-EXCEEDS-CAP

  # The exact failing shape from a real host: control mode reached, complete block, session
  # reported, then %exit with no window. This passed the old criterion, which is why this harness
  # reported a working transport while the app it stands in for showed an empty mirror.
  run_scenario q4exit "4 5 7" "FAKE_EXIT_BEFORE_WINDOW=1"
  expect_verdict q4exit Q4 FAIL
  expect q4exit "%exit before any window arrived"

  # -CC spawns but stays silent: live-but-mute must not read as PASS.
  run_scenario q4fail "4 5 7" "FAKE_NO_CC=1"
  expect_verdict q4fail Q4 FAIL
  expect_verdict q4fail Q5 INCONCLUSIVE
  expect_verdict q4fail Q7 INCONCLUSIVE

  # A %begin with no %end, then silence: matching the two lines separately called this PASS.
  run_scenario q4partial "4 5 7" "FAKE_PARTIAL_BLOCK=1"
  expect_verdict q4partial Q4 FAIL

  # A name collision means the session is not ours: nothing may be graded against it.
  run_scenario q4dup "4 5 6 7" "FAKE_DUP_SESSION=1"
  expect_verdict q4dup Q4 INCONCLUSIVE
  expect_verdict q4dup Q6 INCONCLUSIVE
  expect q4dup "did not create"

  # The handshake lands mid-line behind login noise.
  run_scenario q5mid "4 5 7" "FAKE_HANDSHAKE=midline"
  expect_verdict q5mid Q4 PASS
  expect_verdict q5mid Q5 MID-LINE

  # The session dies with its client.
  run_scenario q6fail "4 5 6 7" "FAKE_SURVIVES=0"
  expect_verdict q6fail Q6 FAIL

  # The base session dies but its grouped sibling lives. Real tmux resolves has-session by
  # prefix, so a prefix query answers yes through the sibling and reports survival that did not
  # happen; the exact =NAME query must report FAIL.
  run_scenario q6sibling "4 5 6 7" "FAKE_SIBLING_ONLY=1"
  expect_verdict q6sibling Q6 FAIL

  # The control stream goes deaf after the handshake.
  run_scenario q7fail "4 5 7" "FAKE_NO_LISTWINDOWS=1"
  expect_verdict q7fail Q4 PASS
  expect_verdict q7fail Q7 FAIL

  # Pane output containing "3 panes" plus an unrelated completed block, and no reply to
  # list-windows: two independent matches called this PASS.
  run_scenario q7async "4 5 7" "FAKE_ASYNC_PANES=1"
  expect_verdict q7async Q4 PASS
  expect_verdict q7async Q7 FAIL

  # The direct argv order (destination last, no wrapper flags), which is what the harness uses
  # against a local etserver. Shipping a second argv shape without a scenario would mean the one
  # the unattended runs depend on is the untested one.
  run_scenario direct "1 2 3 4 5 6 7" "FAKE_LIMIT=4095 FAKE_REQUIRE_ET=0" "TRANSPORT_MODE=direct BROKER_ARGS="
  expect_verdict direct Q1 PASS
  expect_verdict direct Q3 BUDGET-FITS
  expect_verdict direct Q4 PASS
  expect_verdict direct Q6 PASS
  expect_verdict direct Q7 PASS
  expect_rc direct 0

  # Auth never happens: INCONCLUSIVE, not FAIL, and no hang.
  run_scenario hang "1 2" "FAKE_HANG=1 FAKE_OTP=0" "AUTH_TIMEOUT=4"
  expect_verdict hang Q1 INCONCLUSIVE
  expect hang "no OTP was echoed"
  # And with nothing delivered, the escalation must not type at whatever prompt is up.
  expect_absent hang "supplying a line terminator, then exiting the remote shell"
  expect hang "not typing at an unknown prompt"

  # An OTP is echoed and then the broker goes quiet: this is the real failure that wedged a run.
  # It must be reported against the connect budget, must not claim the passcode was accepted,
  # and must not type into the pending prompt.
  run_scenario otpstall "1 2" "FAKE_STALL_AFTER_AUTH=1" "AUTH_TIMEOUT=6 CONNECT_TIMEOUT=4"
  expect_verdict otpstall Q1 INCONCLUSIVE
  expect otpstall "submitted, not necessarily accepted"
  expect_absent otpstall "supplying a line terminator, then exiting the remote shell"
  expect otpstall "not typing at an unknown prompt"

  # A rejected OTP hands control back to the human, so the human budget restarts instead of the
  # connect budget being spent on a connection that was never authorized.
  run_scenario otpreject "1 2" "FAKE_REJECT_ONCE=1 FAKE_LIMIT=4095"
  expect_verdict otpreject Q1 PASS
  expect otpreject "rejected an OTP"

  say ""
  say "SELFTEST: ${ST_PASS} passed, ${ST_FAIL} failed (of $((ST_PASS+ST_FAIL)) assertions)"
  [ "$ST_FAIL" -eq 0 ]
}

# ---------- dispatch ----------
case "$MODE" in
  run)      cmd_run;;
  cleanup)  cmd_cleanup;;
  selftest) cmd_selftest;;
  _fake)    shift; fake_main "$@";;
  *)        say "usage: $0 run|selftest|cleanup    (run needs HOST= and PANE=)"; exit 64;;
esac
