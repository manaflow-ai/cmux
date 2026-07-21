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
# Measured so far (all five checks pass, identically):
#   et 6.2.11+7  — the version installed on the machine this was developed against
#   et 7.0.0     — built from source at tag et-v7.0.0
#
# The interesting non-difference: 7.x rewrote the pty input path specifically because 6.x
# deadlocks on a large input burst, yet a >MAX_CANON command is still not delivered on either.
# The limit is a property of the tty line discipline, not of how the server writes to it, so the
# bound cmux relies on survives that rewrite. That was worth measuring rather than assuming in
# either direction — the prediction going in was that 7.x would deliver it.
#
# Usage:
#   scripts/remote-tmux-et-conformance.sh                      # the et on PATH
#   ET_CLIENT=/path/to/et ET_SERVER=/path/to/etserver \
#     ET_TERMINAL=/path/to/etterminal scripts/remote-tmux-et-conformance.sh
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

FAILURES=0
pass() { printf '  ✅ %s\n' "$*"; }
fail() { printf '  ❌ %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
skip() { printf '  ⏭  %s\n' "$*"; }

for tool in ET_CLIENT ET_SERVER ET_TERMINAL; do
  if [ -z "${!tool}" ]; then
    echo "$tool not found; set it explicitly (see usage)" >&2
    exit 2
  fi
done

VERSION="$("$ET_CLIENT" --version 2>&1 | head -1)"
echo "=== conformance against: $VERSION"
echo "    client=$ET_CLIENT server=$ET_SERVER terminal=$ET_TERMINAL"

STATE="$(mktemp -d "${TMPDIR:-/tmp}/cmux-et-conformance.XXXXXX")" || exit 1
PIDFILE="$STATE/etserver.pid"
cleanup() {
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
  tmux kill-session -t "$SESSION" 2>/dev/null
  rm -rf "$STATE"
}
trap cleanup EXIT

mkdir -p "$STATE/logs"
"$ET_SERVER" --port "$PORT" --bindip 127.0.0.1 --pidfile "$PIDFILE" \
             --logdir "$STATE/logs" --daemon >"$STATE/logs/start.out" 2>&1
for _ in $(seq 1 30); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.5; done
nc -z 127.0.0.1 "$PORT" 2>/dev/null || { echo "etserver did not start on $PORT" >&2; exit 1; }

# Every check runs the command the way cmux does: through the pty allocator, with the terminal
# path named rather than assumed.
et_run() {
  local timeout_s="$1" command="$2"
  timeout "$timeout_s" /usr/bin/script -q /dev/null \
    "$ET_CLIENT" -p "$PORT" --terminal-path "$ET_TERMINAL" -c "$command" "$HOST" 2>&1
}

echo "--- claim: the remote command runs in a LOGIN shell, so it inherits the user's PATH"
# cmux dropped ssh's PATH resolver from the ET argv on the strength of this. If it is false, the
# transport cannot find tmux on a host where tmux is outside the default PATH.
out="$(et_run 25 'exec sh -c "command -v tmux || echo NO_TMUX"')"
if printf '%s' "$out" | grep -q '/tmux'; then
  pass "a login shell resolves tmux from PATH"
else
  fail "tmux did not resolve in the remote shell — the ET argv still needs a PATH resolver"
fi

echo "--- claim: a command longer than one canonical line is NOT delivered"
# This is why cmux sends plain \`tmux\` instead of its ~1113-byte resolver. et types the command
# into a pty; canonical mode caps a line (MAX_CANON, 1024 on macOS). 6.x deadlocks, 7.x buffers —
# either way it must not silently appear to work.
short_out="$(et_run 20 'exec /bin/echo SHORT_OK')"
if printf '%s' "$short_out" | grep -q SHORT_OK; then
  pass "a short command is delivered and runs"
else
  fail "a short command did not run — the harness itself is broken, not the claim"
fi
pad="$(printf 'x%.0s' $(seq 1 1100))"
long_out="$(et_run 20 "exec /bin/echo LONG_OK_${pad}")"; long_rc=$?
if [ "$long_rc" -ne 0 ] || ! printf '%s' "$long_out" | grep -q "LONG_OK_x"; then
  pass "a >MAX_CANON command does not complete (rc=$long_rc) — the length bound is real"
else
  fail "a 1100+ byte command RAN: this version delivers long lines, so the bound cmux relies on has moved"
fi

echo "--- claim: the control-mode enter DCS arrives mid-line, behind the shell's echo"
# cmux's parser used to require the DCS at the start of a line, and never entered control mode.
tmux -f /dev/null new-session -d -s "$SESSION" 2>/dev/null
cc_out="$(et_run 20 "exec tmux -CC attach-session -t $SESSION")"
if printf '%s' "$cc_out" | grep -q '%begin'; then
  # Anything before the DCS on its line is what a start-of-line matcher would choke on.
  if printf '%s' "$cc_out" | grep -qE '.+\x1bP1000p|.+P1000p%begin'; then
    pass "the enter DCS is preceded on its line by shell output (a start-of-line match would miss it)"
  else
    pass "control mode entered; the DCS happened to open its line this time"
  fi
else
  fail "no %begin over et — the control stream did not reach control mode"
fi

echo "--- claim: end-of-stream does NOT mean the remote session is gone"
# cmux used to treat an ET exit as the session ending, and removed the mirror. Restarting only
# etserver falsifies that: the stream ends, the session lives.
kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
rm -f "$PIDFILE"
sleep 1
if tmux has-session -t "$SESSION" 2>/dev/null; then
  pass "the session survives the transport dying, so EOF must lead to a reattach"
else
  fail "the session died with the transport — EOF would then be a fair signal for session-over"
fi

echo "=== $FAILURES failed check(s) against $VERSION"
exit "$FAILURES"
