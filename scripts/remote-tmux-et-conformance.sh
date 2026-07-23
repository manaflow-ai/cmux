#!/bin/bash
# ============================================================================
# Checks the things cmux believes about `et`, against `et`.
#
# The ET transport shipped with six defects that shared one cause: its load-bearing claims about
# EternalTerminal lived in a design doc and in comments, and nothing executed them. Unit tests
# could not catch any of them — they assert what cmux builds, which is the model, not what the
# other program does. 77 of them passed while the transport could not carry a stream at all.
#
# So each claim gets one check here. A claim that cannot be written as a check is an assumption,
# and belongs in the PR as one.
#
# Version matters more than usual. ET is not as widely deployed as tmux, and its behaviour does
# move between series: 7.x rewrote the pty input path that 6.x deadlocks on. Run this against
# every version you intend to support and treat a divergence as a finding.
#
# Measured against et 6.2.11+7 and et 7.0.0 (built from source at tag et-v7.0.0), and then
# cross-checked against ET's own source, which settled three things measurement alone left open:
#
#   TerminalClient.cpp        tb.set_buffer(command + "; exit\n")
#   PsuedoUserTerminal.hpp    forkpty(&masterFd, NULL, NULL, NULL)
# The `-c` command really is delivered as terminal INPUT to a login shell on a pty, with `; exit`
# appended, in both series. That is the root of every constraint below. et also has a `--noexit`
# flag that sends `command + "\n"` instead, which would return those 7 bytes to the budget.
#
#   UserTerminalHandler.cpp   6.x: RawSocketUtils::writeAll(masterFd, …)   -- one blocking write
#                             7.x: pendingInput.append(…) then a non-blocking drain
# 7.x rewrote this to stop a large burst blocking its event loop. It did NOT raise the limit: a
# canonical-mode pty still refuses a line past MAX_CANON, so the bound belongs to the line
# discipline rather than to how the server writes, and it is identical across both series. That
# claim used to be an inference here; it is now read from the code.
#
#   TerminalClientMain.cpp    if (!result.count("N")) console.reset(new PsuedoTerminalConsole());
#                             (6.2.11 spelling; 7.0.0 spells it PseudoTerminalConsole)
#   PsuedoTerminalConsole.hpp tcgetattr(0, …); cfmakeraw(…); tcsetattr(0, …)   -- returns unchecked
# So the client does not require a tty, but it does not tolerate its absence by design either: it
# always builds a console unless `-N` is given, and the termios calls simply fail silently on a
# pipe. Control mode still comes up (measured, including with no controlling terminal at all), but
# with no usable termios the client cannot suppress local echo, which is why the same stream is
# far larger without a pty (measured 1324 bytes with vs 44576 without, one session on a loopback
# server). `-N` is not an alternative: it discards the stream entirely.
# The interesting non-difference: 7.x rewrote the pty input path specifically because 6.x
# deadlocks on a large input burst, yet the delivery bound is unchanged. The limit belongs to the
# tty line discipline, not to how the server writes to it, so it survives that rewrite.
#
# THE LENGTH BOUND IS PLATFORM-DEPENDENT, WHICH THIS FILE USED TO GET WRONG. It asserted that a
# 1100-byte command fails, which holds only where MAX_CANON is 1024, as on macOS. On Linux it is
# 4096, so the same assertion fails against a Linux host with nothing actually broken — measured
# there, a 4001-byte command was delivered intact and a 4152-byte one was truncated mid-quote,
# leaving the remote shell on a continuation prompt. The bound is now measured by bisection and
# cross-checked against what the host itself reports, instead of asserted from one platform.
#
# Two further corrections, both real. The DCS position is not fixed: it lands at the start of its
# line on a host whose shell emits a newline before tmux's output, and mid-line on one that does
# not, so it is reported rather than asserted — which is the actual reason cmux's parser must scan
# anywhere. And this script used to create its tmux session on the user's DEFAULT tmux server,
# which it must never touch.
#
# Usage:
#   scripts/remote-tmux-et-conformance.sh                      # the et on PATH
#   ET_CLIENT=/path/to/et ET_SERVER=/path/to/etserver \
#     ET_TERMINAL=/path/to/etterminal scripts/remote-tmux-et-conformance.sh
#
#   # The same checks through a wrapper that fronts the client for hosts that are not directly
#   # reachable. The wrapper supplies the endpoint, so no port or terminal path is passed, and its
#   # own flags must precede the destination.
#   TRANSPORT_BROKER=/path/to/broker TRANSPORT_BROKER_ARGS="-et -fallback" \
#     TRANSPORT_HOST=somehost scripts/remote-tmux-et-conformance.sh
#
# Exit code is the number of failed checks (0 = every belief holds).
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

ET_CLIENT="${ET_CLIENT:-$(command -v et || true)}"
ET_SERVER="${ET_SERVER:-$(command -v etserver || true)}"
# Resolved, not assumed. A literal path is a claim about someone else's machine, and cmux
# hardcoding one of these is itself one of the defects this file exists to prevent.
ET_TERMINAL="${ET_TERMINAL:-$(command -v etterminal || true)}"
PORT="${CMUX_ET_PORT:-2041}"
HOST="${CMUX_ET_HOST:-cmux-ethost}"
SESSION="cmux-conformance-$$"

# Optional brokered mode. Empty means talk to a loopback etserver directly.
TRANSPORT_BROKER="${TRANSPORT_BROKER:-}"
TRANSPORT_BROKER_ARGS="${TRANSPORT_BROKER_ARGS:-}"
TRANSPORT_HOST="${TRANSPORT_HOST:-}"

# What cmux actually puts on the line, which is NOT the same as the MAX_CANON constant it
# compares against internally. RemoteTmuxETTransportProfile keeps maxCanonicalLineBytes = 1024
# (the kernel limit) and spends only deliverableCommandBytes = 1024 - 96, reserving the rest for
# et's appended "; exit" and the shell's line editing.
#
# Comparing the kernel constant against a measured delivery bound is a units error: it failed by
# 8 bytes while the code was in fact safe by 88. The number checked here has to be the budget the
# code spends, because that is the thing that either fits or gets truncated.
CMUX_ASSUMED_BOUND="${CMUX_ASSUMED_BOUND:-928}"

# Where to mirror transport output so a human can see an auth prompt. /dev/tty when there is one,
# otherwise nowhere — which keeps the loopback (unauthenticated, headless, CI) path unchanged.
if { : > /dev/tty; } 2>/dev/null; then TTY_SINK=/dev/tty; else TTY_SINK=/dev/null; fi

# ONE MECHANISM: this always runs with a real terminal, because it re-execs itself inside a tmux
# pane when it does not have one.
#
# The alternative was branching on `[ -t 0 ]` and using script(1) interactively vs a synthesised pty
# headlessly. That branch is how this harness broke in both directions: the pty helper relayed no
# stdin so a 2FA passcode never reached the client, and script(1) aborts when stdin is a socket. A
# pane is a real tty in both cases, so there is nothing to choose and nothing to get wrong — and the
# headless path then exercises exactly the code the interactive path uses.
if [ -z "${CMUX_CONF_IN_PANE:-}" ] && [ ! -t 0 ]; then
  pane_dir="$(mktemp -d /tmp/cmux-conf-pane.XXXXXX)"   # short path: a socket is capped near 104 bytes
  export TMUX_TMPDIR="$pane_dir"
  unset TMUX
  done_file="$pane_dir/done"
  # `remain-on-exit` is not used: the pane must close so the wait below has a real edge.
  tmux new-session -d -s conf -x 200 -y 50 \
    "CMUX_CONF_IN_PANE=1 $(printf '%q ' "$0" "$@") > $pane_dir/out 2>&1; echo \$? > $done_file"
  for _ in $(seq 1 3600); do
    [ -s "$done_file" ] && break
    tmux has-session -t conf 2>/dev/null || break
    sleep 1
  done
  cat "$pane_dir/out" 2>/dev/null
  rc=$(cat "$done_file" 2>/dev/null || echo 1)
  tmux kill-server 2>/dev/null
  rm -rf "$pane_dir"
  exit "$rc"
fi

FAILURES=0
ET_RUN_SEQ=0      # set -u: must exist before $((++ET_RUN_SEQ))
pass() { printf '  ✅ %s\n' "$*"; }
fail() { printf '  ❌ %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
note() { printf '     %s\n' "$*"; }
skip() { printf '  ⏭  %s\n' "$*"; }

# tmux gets its own socket directory. This script must never create or kill anything on the user's
# default server, which may be hosting their real work. A nonexistent TMUX_TMPDIR silently falls
# back to the default socket, so it is created before first use.
# Deliberately /tmp and not $TMPDIR. A unix socket path is capped at about 104 bytes, and macOS
# sets TMPDIR to a long /var/folders/... path; putting the tmux socket dir under it produced
# "error connecting to .../tmux-501/default (File name too long)", which then looked like three
# separate transport failures — no control mode, no data, no surviving session.
STATE="$(mktemp -d "/tmp/cmux-etconf.XXXXXX")" || exit 1
export TMUX_TMPDIR="$STATE/tmux"
mkdir -p "$TMUX_TMPDIR" "$STATE/logs"
unset TMUX
PIDFILE="$STATE/etserver.pid"

cleanup() {
  tmux kill-server 2>/dev/null      # safe: TMUX_TMPDIR is this run's own directory
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
  # Keep the evidence when anything failed. Deleting it unconditionally destroys the raw stream
  # that explains the failure, so a red run cannot be investigated afterwards.
  if [ "$FAILURES" -gt 0 ]; then
    echo "=== artifacts kept for inspection: $STATE"
  else
    rm -rf "$STATE"
  fi
}
trap cleanup EXIT

if [ -n "$TRANSPORT_BROKER" ]; then
  [ -x "$TRANSPORT_BROKER" ] || { echo "TRANSPORT_BROKER is not executable: $TRANSPORT_BROKER" >&2; exit 2; }
  [ -n "$TRANSPORT_HOST" ] || { echo "TRANSPORT_HOST is required in brokered mode" >&2; exit 2; }
  MODE="brokered via $TRANSPORT_BROKER"
  VERSION="(the broker supplies the client)"
else
  for tool in ET_CLIENT ET_SERVER ET_TERMINAL; do
    if [ -z "${!tool}" ]; then
      echo "$tool not found; set it explicitly (see usage)" >&2
      exit 2
    fi
  done
  MODE="direct to a loopback etserver on $PORT"
  VERSION="$("$ET_CLIENT" --version 2>&1 | head -1)"
fi

echo "=== conformance against: $VERSION"
echo "    mode: $MODE"
[ -z "$TRANSPORT_BROKER" ] && echo "    client=$ET_CLIENT server=$ET_SERVER terminal=$ET_TERMINAL"

if [ -z "$TRANSPORT_BROKER" ]; then
  # Bind loopback only. An et server hands out real shells and must not be reachable off-box.
  "$ET_SERVER" --port "$PORT" --bindip 127.0.0.1 --pidfile "$PIDFILE" \
               --logdir "$STATE/logs" --daemon >"$STATE/logs/start.out" 2>&1
  for _ in $(seq 1 30); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.5; done
  nc -z 127.0.0.1 "$PORT" 2>/dev/null || { echo "etserver did not start on $PORT" >&2; exit 1; }
fi

# Every check runs the command the way cmux does: through the pty allocator, with the terminal
# path named rather than assumed. In brokered mode the endpoint flags are omitted, because the
# broker resolved the endpoint and cmux's guesses would override it — and because a client flag
# placed before the destination is rejected outright by the wrapper.
# Extra patience for every brokered connection, because a human has to notice a prompt and touch
# a security key before anything can happen. The per-check timeouts below are sized for a loopback
# server that answers in milliseconds; against a broker they are nowhere near enough, and a
# too-short one does not fail honestly — it reports the transport as broken. Measured the hard way:
# a 25-second gate timed out while the user was reaching for their key, and the run aborted with a
# precondition failure that had nothing to do with the transport.
HUMAN_GRACE="${HUMAN_GRACE:-600}"

# ET_RUN_STDIN, when set, is fed to the child on stdin. Only meaningful because pty-run.py relays
# stdin; before that fix nothing typed here could reach the client.
et_run() {
  local timeout_s="$1" command="$2"
  # Unique per call so a caller cannot read a previous run's transcript.
  local T_SCRIPT="${STATE:-/tmp}/etrun-$$-$((++ET_RUN_SEQ)).script"
  ET_RUN_LOG="$T_SCRIPT"
  if [ -n "$TRANSPORT_BROKER" ] && [ -z "${ET_RUN_NO_GRACE:-}" ]; then
    timeout_s=$(( timeout_s + HUMAN_GRACE ))
  fi
  # The remote shell gets the socket dir explicitly. Without this the local side is isolated and
  # the remote side is not, which is worse than no isolation because it looks safe: et's remote
  # login shell does not inherit TMUX_TMPDIR, so its tmux silently used the DEFAULT socket.
  # Added only for commands that actually run tmux — the prefix is ~60 bytes, and adding it to
  # the length probes would shift the measured bound by that much.
  case "$command" in
    *tmux*) command="TMUX_TMPDIR=$TMUX_TMPDIR; export TMUX_TMPDIR; $command" ;;
  esac
  # scripts/pty-run.py rather than script(1): script copies terminal settings from the tty it
  # inherits, so with stdin a socket — a background job, a CI step — it aborts with
  # "tcgetattr/ioctl: Operation not supported on socket" and the command never runs. That looks
  # identical to ET producing no output, which is what a genuinely broken transport looks like.
  if [ -n "$TRANSPORT_BROKER" ]; then
    # shellcheck disable=SC2086
    # script(1), not pty-run.py, and no pipe. An interactive transport needs a real terminal on
    # BOTH ends, and every wrapper added here to make it observable took one away:
    #   pty-run.py relayed no stdin, so a 2FA passcode never reached the client;
    #   `| tee` made stdout a pipe, and then the client emitted nothing at all;
    #   out=$(...) swallowed the prompt, so there was nothing to answer;
    #   feeding a terminator on stdin had it consumed by the prompt instead.
    # script(1) relays stdin by design and writes a transcript, which is the whole requirement.
    # Everything that worked against a real broker today was this shape; everything that hung was
    # one of the wrappers above.
    # Pick by whether stdin is a real terminal, because the two cases have opposite requirements
    # and neither mechanism serves both:
    #   a human may have to answer a 2FA prompt, and only an unwrapped stdio pair reaches them.
    #     script(1) relays stdin by design; a pipe, a $( ), or a pty helper that forwards nothing
    #     all swallow the prompt, and the run then looks like the remote transport stalling.
    #   headless (CI, a background job, stdin a socket) has no terminal to borrow, and script(1)
    #     aborts there with "tcgetattr/ioctl: Operation not supported on socket", so a synthesised
    #     pty is required — pty-run.py, which also relays stdin.
    # Forcing either onto the other's path broke this harness in both directions today.
    # Unconditional: a tty is guaranteed by the pane re-exec above, so script(1) always works and
    # always relays stdin — which is what lets a human answer a 2FA prompt.
    /usr/bin/script -q "$T_SCRIPT" \
      "$TRANSPORT_BROKER" $TRANSPORT_BROKER_ARGS "$TRANSPORT_HOST" -c "$command"
    ET_RUN_LOG="$T_SCRIPT"
  else
    python3 scripts/pty-run.py --timeout "$timeout_s" -- \
      "$ET_CLIENT" -p "$PORT" --terminal-path "$ET_TERMINAL" -c "$command" "$HOST" 2>&1 \
      | tee "$TTY_SINK"
  fi
}

# Byte length of everything delivered() wraps around its padding, so the sweep can be expressed
# in total line bytes. Measured once with an empty payload rather than counted by eye.
probe_wrapper_bytes() {
  local empty
  empty="exec sh -c 'echo  | wc -c | tr -d \" \" | tr 0-9 ABCDEFGHIJ'"
  printf '%s' "${#empty}"
}
WRAPPER_BYTES="$(probe_wrapper_bytes)"

delivered() {
  local n="$1" pad out want padlen
  # n is the TOTAL command length, so the padding is n minus what wraps it.
  padlen=$(( n - WRAPPER_BYTES ))
  [ "$padlen" -lt 1 ] && padlen=1
  pad="$(printf 'x%.0s' $(seq 1 "$padlen"))"
  # The remote counts the bytes and reports the count, so the evidence cannot be forged by the
  # shell's echo of the command. Grepping for a literal that appears IN the command passes even
  # when nothing ran — that reported an 8192-byte command as delivered on a host whose limit is
  # 1024. Digits are mapped to letters because the command text contains digits of its own.
  want="$(printf '%s' "$((padlen + 1))" | tr 0-9 ABCDEFGHIJ)"
  # PIPESTATUS[0], not the pipeline status: et_run pipes through `tee`, so `$?` is tee's and a
  # timeout looked identical to a truncated line. pty-run.py returns 124 on timeout like timeout(1),
  # and folding that into the bisection could manufacture a bound on a transport that has none.
  # No human grace here: auth has already happened by this point, and an over-limit probe can
  # never return — its truncated line loses the closing quote AND the `; exit` et appends, so the
  # remote shell waits at a continuation prompt forever. The timeout is the measurement.
  # Quote-free on purpose. The pad used to sit inside a single-quoted `sh -c '…'`, so a truncated
  # line lost its closing quote and zsh parked on `quote>` waiting for the rest — and the `; exit`
  # et appends was in the dropped tail, so that shell never left and the client never exited.
  # Bare `x` characters need no quoting, and `tr 0-9 ABCDEFGHIJ` needs none either.
  #
  # No stdin injection. Feeding a terminator was tried and is wrong: pty-run relays stdin
  # immediately, so the bytes arrive BEFORE the remote command and get eaten by the auth prompt —
  # observed as a bare `exit` echoed above the passcode line. There is no edge to time it against
  # from out here, so the bounded timeout below is the terminator instead.
  # No capture: the prompt must reach the terminal. script(1) mirrors the transport to a transcript,
  # and that transcript is the evidence. `out=$(et_run ...)` would swallow a 2FA prompt — which is
  # exactly how the precondition gate ended up invisible, because the gate calls this function.
  ET_RUN_NO_GRACE=1 et_run 45 "echo ${pad} | wc -c | tr 0-9 ABCDEFGHIJ"
  local rc=$? out=""
  [ -n "${ET_RUN_LOG:-}" ] && out="$(cat "$ET_RUN_LOG" 2>/dev/null)"
  if [ "$rc" -eq 124 ]; then
    # Expected for an over-limit line: the remote shell is parked on a continuation prompt and the
    # client will never exit. Killing it is how the probe ends, and "not delivered" is the answer.
    return 1
  fi
  # Escape sequences are stripped before matching. The remote shell emits an OSC title on the
  # same line as the reply, so the token arrives glued to it (\x1b]1;exec + "GF") and a
  # whole-line match cannot see it — which reported "even a 64-byte command was not delivered"
  # while the reply was sitting right there in the transcript.
  printf '%s' "$out" | python3 -c '
import re, sys
d = sys.stdin.buffer.read()
d = re.sub(b"\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)", b"", d)   # OSC
d = re.sub(b"\x1b\\[[0-9;?]*[A-Za-z]", b"", d)                     # CSI
d = re.sub(b"\x1b.", b"", d)
want = sys.argv[1].encode()
sys.exit(0 if re.search(b"(?:^|[^A-J])" + want + b"(?:[^A-J]|$)", d) else 1)  # spaces ok: not in [A-J]
' "$want"
}

# ---------------------------------------------------------------------------
# PRECONDITION GATE. Nothing below runs unless one trivial command survives the round trip.
#
# Without this the script happily reported six per-claim failures while its own etserver had
# died — "tmux is not on PATH", "control mode was not reached", "the session did not survive" —
# every one of them a statement about a transport that was not running. A harness that emits
# findings when its own plumbing is down is worse than no harness, because the findings look
# exactly like real ones. `nc -z` is not sufficient evidence: the port was open when it was
# checked and the server was gone moments later, and the etserver on this machine is
# independently known to stop serving while still holding its port.
#
# So the gate is an end-to-end echo, and a failure here exits with a precondition error rather
# than a verdict about any claim.
# ---------------------------------------------------------------------------
# Note the dependency this creates: the gate needs `wc` and `tr` on the remote PATH, because that
# is how it obtains a reply the remote computed rather than one it could have echoed. A host without
# them fails the gate, which is the honest outcome — the harness cannot verify delivery there.
#
# `delivered` is used rather than a marker of our own, because any literal we send is echoed back
# by the remote login shell: grepping for it passes even when the command failed to execute. It
# requires a byte count the remote computes, which an echo cannot produce.
if delivered 200; then gate_ok=1; else gate_ok=0; fi
if [ "$gate_ok" -ne 1 ]; then
  gate_out="$(cat "$T" 2>/dev/null || true)"
  echo "  ⛔ PRECONDITION FAILED: a trivial command did not survive the transport." >&2
  echo "     No claim was tested, so no claim is being reported. Fix the transport and re-run." >&2
  printf '     last output: %s\n' "$(printf '%s' "$gate_out" | tail -3 | tr -d '\r' | tr '\n' ' ')" >&2
  if [ -z "$TRANSPORT_BROKER" ]; then
    echo "     etserver listening on $PORT? $(nc -z 127.0.0.1 "$PORT" 2>/dev/null && echo yes || echo NO)" >&2
    tail -5 "$STATE/logs"/* 2>/dev/null | sed 's/^/     /' >&2
  fi
  exit 90
fi
echo "=== precondition holds: a trivial command survives the transport"

echo "--- claim: a pty is what keeps the stream bounded, and -N discards it entirely"
# This is why the profile carries requiresPseudoTerminal and the spawn is wrapped in script(1). A
# silent transport is indistinguishable from an unreachable host, which is what made the original
# failure expensive to diagnose.
if [ -n "$TRANSPORT_BROKER" ]; then
  skip "not checked in brokered mode: a failed connection also produces nothing"
else
  # The old version of this check asserted that et is silent on a pipe. It is not, so the check
  # could only fail against a healthy et. What is true, and what cmux actually depends on:
  #   - control mode IS reached over pipes, so the pty is not what makes the transport work;
  #   - without usable termios the client cannot go raw, so the same stream arrives far larger,
  #     padded with redraws, and cmux parses and budgets against that stream;
  #   - `-N` suppresses the console, and et writes the remote output only when a console exists,
  #     so it receives the stream and discards it.
  # The last one is the sharp, cheap assertion, so that is what is checked here.
  tmux -f /dev/null new-session -d -s "${SESSION}p" 2>/dev/null
  PCMD="TMUX_TMPDIR=$TMUX_TMPDIR; export TMUX_TMPDIR; exec tmux -CC attach-session -t ${SESSION}p"
  withpty="$(python3 scripts/pty-run.py --timeout 20 -- "$ET_CLIENT" -p "$PORT" \
               --terminal-path "$ET_TERMINAL" -c "$PCMD" "$HOST" 2>&1)" || true
  withN="$(python3 scripts/pty-run.py --timeout 20 -- "$ET_CLIENT" -N -p "$PORT" \
               --terminal-path "$ET_TERMINAL" -c "$PCMD" "$HOST" 2>&1)" || true
  wp_bytes=$(printf '%s' "$withpty" | wc -c | tr -d ' ')
  wn_bytes=$(printf '%s' "$withN" | wc -c | tr -d ' ')
  if printf '%s' "$withpty" | grep -q '%begin'; then
    pass "under a pty the stream carries control mode (${wp_bytes} bytes)"
  else
    fail "no control mode even under a pty — something more basic is wrong"
  fi
  if printf '%s' "$withN" | grep -q '%begin'; then
    fail "-N still delivered the stream; cmux could drop the pty wrapper and pass -N instead"
  elif printf '%s' "$withN" | grep -qE "Could not reach|onnection refused|uthentication|rror"; then
    # Absence of %begin only means something if the run actually connected. Without this, an
    # unreachable port scored as "-N discards the stream" — measured.
    fail "the -N run did not connect, so its lack of a stream proves nothing"
    note "$(printf '%s' "$withN" | tr -d '\r' | grep -aE 'Could not reach|rror' | head -1)"
  else
    pass "-N connected and still produced no stream (${wn_bytes} bytes), so it is not an alternative"
  fi
  # Absent a pty the stream is padded with redraws. Reported rather than asserted: the exact
  # multiple depends on the shell and the window size, and only its magnitude matters.
  nopty="$(timeout 20 "$ET_CLIENT" -p "$PORT" --terminal-path "$ET_TERMINAL" \
             -c "$PCMD" "$HOST" </dev/null 2>&1)" || true
  np_bytes=$(printf '%s' "$nopty" | wc -c | tr -d ' ')
  note "same session: ${wp_bytes} bytes under a pty vs ${np_bytes} without one"
  tmux kill-session -t "${SESSION}p" 2>/dev/null
fi

echo "--- claim: the remote command runs in a LOGIN shell, so it inherits the user's PATH"
# cmux dropped ssh's PATH resolver from the ET argv on the strength of this. If it is false, the
# transport cannot find tmux on a host where tmux is outside the default PATH.
# Upper-cased by the remote, so the reply cannot be satisfied by the request: this harness prepends
# `TMUX_TMPDIR=<dir>/tmux` to any command mentioning tmux, and the old `grep -q '/tmux'` matched
# that prefix — reproduced passing with PATH=/nonexistent, i.e. green with no tmux at all.
et_run 25 'exec sh -c "command -v tmux | tr a-z A-Z || echo NO_TMUX"'
out="$(cat "${ET_RUN_LOG:-/dev/null}" 2>/dev/null)"
if printf '%s' "$out" | grep -qE '/[A-Z0-9_./-]*TMUX'; then
  pass "a login shell resolves tmux from PATH ($(printf '%s' "$out" | grep -oE '/[A-Z0-9_./-]*TMUX' | head -1))"
else
  fail "tmux did not resolve in the remote shell — the ET argv still needs a PATH resolver"
fi

echo "--- claim: a command longer than one canonical line is NOT delivered"
# Same reasoning as the gate: a literal marker is satisfied by the shell's echo of the command.
if delivered 200; then
  pass "a short command is delivered and runs (verified by a reply the remote computed)"
else
  fail "a short command did not run — the harness itself is broken, not the claim"
fi

# The POSIX MAX_CANON value is ADVISORY and must not be read as the limit.
#
# Measured on a Linux host: `fpathconf(PC_MAX_CANON)` reports 255, and lines of 1000 and 4095 bytes
# were nonetheless delivered whole; delivery capped at 4096 (the kernel's N_TTY_BUF_SIZE) with a
# 5000-byte write. So the reported number is not enforced there, and treating agreement between it
# and the measurement as corroboration is backwards — on any Linux host they will disagree by
# design. It cost real time: the reported 255 was briefly believed over a 4001-byte delivery this
# same harness had already observed, and produced a false alarm that cmux's budget was 4x too big.
#
# It is still worth printing, because a disagreement is informative about the platform. It is
# printed as advisory, and nothing is derived from it. The measured bound below is authoritative.
et_run 20 'exec python3 -c "import os,sys;print(\"REPORTED=%d\" % os.fpathconf(sys.stdin.fileno(),\"PC_MAX_CANON\"))"'
reported="$(tr -d '\r' < "${ET_RUN_LOG:-/dev/null}" 2>/dev/null | sed -n 's/.*REPORTED=\([0-9]*\).*/\1/p' | head -1)"
if [ -n "$reported" ]; then
  note "the host advertises MAX_CANON = $reported bytes (advisory; Linux does not enforce it, so"
  note "expect this to disagree with the measurement below — the measurement is what counts)"
else
  note "the host would not advertise MAX_CANON (no python3?); the measurement below is what counts"
fi

# Measure the real threshold instead of asserting one platform's constant. Bisection is affordable
# because the loopback server needs no authentication.
lo=64; hi=8192
# A brokered connection costs one human key press each, so a nine-sample bisection costs nine.
# BISECT_SAMPLES=coarse brackets the bound with two, which is enough to confirm cmux's budget
# fits inside it — the exact threshold is only interesting on the free loopback path.
if [ -n "$TRANSPORT_BROKER" ] && [ "${BISECT_SAMPLES:-coarse}" = coarse ]; then
  COARSE=1
else
  COARSE=0
fi
if ! delivered "$lo"; then
  fail "even a ${lo}-byte command was not delivered — the bound cannot be measured"
elif [ -n "${NO_LINE_LIMIT:-}" ]; then
  # Set only by a caller that knows the transport does not type its command into a pty — a
  # substitute taking argv, for instance. Reporting a missing bound as a failure there made the
  # harness invent a finding against a healthy transport.
  skip "this transport does not type its command into a terminal, so no line bound applies"
elif delivered "$hi"; then
  fail "an ${hi}-byte command was delivered, so this host has no bound in range; cmux's budget rests on a limit it does not have"
else
  if [ "$COARSE" = 1 ]; then
    # Just enough to answer the question that matters: does cmux's budget fit?
    if delivered "$CMUX_ASSUMED_BOUND"; then lo=$CMUX_ASSUMED_BOUND; else hi=$CMUX_ASSUMED_BOUND; fi
    note "coarse mode: bracketed with 2 samples to save key presses (set BISECT_SAMPLES=fine for the exact threshold)"
  else
    while [ $((hi - lo)) -gt 64 ]; do
      mid=$(((lo + hi) / 2))
      if delivered "$mid"; then lo=$mid; else hi=$mid; fi
    done
  fi
  if [ -n "${DELIVERED_INCONCLUSIVE:-}" ]; then
    fail "a length probe timed out twice, so the bracket would rest on a guess — not reporting a bound"
  else
    pass "the length bound is real: delivery stops between $lo and $hi bytes of total command line"
  fi
  # The only thing that actually matters is that what cmux compiles in stays under it.
  if [ "$CMUX_ASSUMED_BOUND" -le "$lo" ]; then
    pass "cmux's assumed bound ($CMUX_ASSUMED_BOUND) is within the measured limit"
  else
    fail "cmux assumes $CMUX_ASSUMED_BOUND bytes but only ~$lo are delivered — commands will be truncated"
  fi
  if [ -n "$reported" ] && [ "$reported" -gt 0 ] && [ "$lo" -gt "$reported" ]; then
    # Expected on Linux, and stated so it is not mistaken for a problem: the advertised value is
    # not the enforced one. Deliberately not scored either way.
    note "delivery exceeds the advertised MAX_CANON ($reported), which is normal where it is advisory"
  fi
fi

echo "--- claim: control mode is reached, and cmux must not require the DCS at a line start"
tmux -f /dev/null new-session -d -s "$SESSION" 2>/dev/null
cc_raw="$STATE/cc.bin"
et_run 20 "exec tmux -CC attach-session -t $SESSION"
cp "${ET_RUN_LOG:-/dev/null}" "$cc_raw" 2>/dev/null || : > "$cc_raw"
if grep -aq '%begin' "$cc_raw"; then
  pass "control mode entered over this transport"
  # Position is REPORTED, not asserted. It depends on the remote shell: one that emits a newline
  # before tmux's output puts the DCS at a line start, one that does not puts it mid-line. Both
  # occur on real hosts, which is exactly why the parser must scan anywhere in the line.
  python3 - "$cc_raw" <<'PY'
import sys, re
d = open(sys.argv[1], 'rb').read()
m = re.search(b'\x1bP1000p', d)
if not m:
    print("     the DCS itself was not in the stream, though %begin was — worth a look")
    raise SystemExit
i = m.start(); nl = d.rfind(b'\n', 0, i); before = d[nl+1:i]
where = "mid-line, behind other output" if before.strip() else "at the start of its line"
print("     the enter DCS arrived %s (%d bytes precede it)" % (where, len(before)))
if before.strip():
    print("     a start-of-line matcher would miss this one: %r" % before[-48:])
j = d.find(b'%begin')
if j > 0:
    print("     %d bytes of login-shell preamble precede the first %%begin" % j)
PY
else
  fail "no %begin over this transport — the control stream did not reach control mode"
fi

echo "--- claim: the stream answers commands, not just the handshake"
# A handshake followed by a deaf stream is indistinguishable from a working one until cmux tries to
# drive it. The session's own command reports through the stream, so no client input is needed and
# the client exits by itself when that command finishes.
ans_raw="$STATE/answer.bin"
et_run 25 "exec tmux -CC new-session -A -s ${SESSION}b 'tmux list-windows -F CTRLDATA:#{window_id}; sleep 1'"
cp "${ET_RUN_LOG:-/dev/null}" "$ans_raw" 2>/dev/null || : > "$ans_raw"
if grep -aq 'CTRLDATA:@' "$ans_raw"; then
  pass "real data crossed the control stream: $(grep -ao 'CTRLDATA:@[0-9]*' "$ans_raw" | head -1)"
else
  fail "nothing but the handshake crossed the stream"
fi

echo "--- claim: an argv the transport rejects fails in wording cmux classifies as unrecoverable"
# cmux must fail fast on a bad argv rather than retry it forever. The wordings here are the ones
# RemoteTmuxSSHTransport.indicatesUnrecoverableTransportFailure knows; a wrapper written in Go
# answers "flag provided but not defined", which is why that string is in the classifier.
if [ -n "$TRANSPORT_BROKER" ]; then
  # shellcheck disable=SC2086
  rej="$(timeout 15 "$TRANSPORT_BROKER" $TRANSPORT_BROKER_ARGS --definitely-not-a-flag \
           "$TRANSPORT_HOST" -c true 2>&1; true)"
else
  # -p must be present, or this fails on connection before argv is ever judged and the
  # connection error gets misread as the rejection wording.
  rej="$(timeout 15 "$ET_CLIENT" -p "$PORT" --definitely-not-a-flag "$HOST" 2>&1; true)"
fi
if printf '%s' "$rej" | grep -qiE "unrecognized option|unknown option|flag provided but not defined|invalid option"; then
  pass "a rejected argv says so in wording cmux classifies as unrecoverable"
  note "$(printf '%s' "$rej" | head -1)"
elif printf '%s' "$rej" | grep -qiE "could not reach|connection refused|timed out"; then
  fail "the probe never got as far as argv parsing, so this check measured nothing"
  note "$(printf '%s' "$rej" | head -1)"
else
  # Not a failure of cmux: a client that ignores unknown flags simply cannot be classified this
  # way, and the classifier's real target is a wrapper that does reject them.
  skip "this client ignores an unknown flag rather than rejecting it — nothing to classify"
  note "$(printf '%s' "$rej" | head -1)"
fi

echo "--- claim: end-of-stream does NOT mean the remote session is gone"
# cmux used to treat an ET exit as the session ending, and removed the mirror. Restarting only
# etserver falsifies that: the stream ends, the session lives.
if [ -n "$TRANSPORT_BROKER" ]; then
  # Skipped, because the check as written proved nothing here. It asked whether `$SESSION` still
  # existed on the harness's own local tmux server — a session the harness created and that nothing
  # in brokered mode ever tries to remove. It therefore passed even in a run where control mode was
  # never reached. The claim needs an observed end-of-stream, which only the loopback path can
  # produce by stopping its own etserver.
  skip "not checked in brokered mode: nothing here ends the stream, so survival cannot be observed"
else
  kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
  rm -f "$PIDFILE"
  sleep 1
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    pass "the session survives the transport dying, so EOF must lead to a reattach"
  else
    fail "the session died with the transport — EOF would then be a fair signal for session-over"
  fi
fi

echo "=== $FAILURES failed check(s) against $VERSION"
exit "$FAILURES"
