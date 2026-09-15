#!/bin/bash
# ============================================================================
# End-to-end: cmux carries a real tmux control stream over a real EternalTerminal.
#
# Everything else about the seam is argv shape and decision rules, which unit tests
# can pin. This is the only check that the app actually drives ET: the pty spawn,
# the ~1.2 KB of login-shell preamble before `%begin`, the CRLF line endings, and
# the control protocol surviving all of it inside the running app.
#
# PREREQUISITES
#   - scripts/remote-tmux-et-host.sh has brought up a loopback etserver.
#   - An ssh alias for that host (one-shot discovery still rides ssh by design).
#   - A tagged Debug app running with remote-tmux beta on; pass CMUX_TAG=<tag>.
#
# Exit code is the number of failed checks (0 = all green).
# ============================================================================
set -uo pipefail

TAG="${CMUX_TAG:?set CMUX_TAG=<tag> of a running tagged Debug app}"
HOST="${CMUX_ET_HOST:-cmux-ethost}"
PORT="${CMUX_ET_PORT:-2039}"
SESSION="${CMUX_ET_SESSION:-etmirror}"
CLI=(scripts/cmux-debug-cli.sh)
FAILURES=0

log()  { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
pass() { printf '  ✅ %s\n' "$*"; }
fail() { printf '  ❌ %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
cli()  { CMUX_QUIET=1 CMUX_TAG="$TAG" "${CLI[@]}" "$@" 2>&1; }

await() {
  local what="$1" timeout="$2"; shift 2
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$@"; then return 0; fi
    sleep 2
  done
  log "timed out after ${timeout}s waiting for: $what"
  return 1
}

cd "$(dirname "$0")/.." || exit 1

app_ready() { cli list-workspaces >/dev/null 2>&1; }
if ! await "the app's control socket" 90 app_ready; then
  log "no response on the tagged app socket for CMUX_TAG=$TAG"
  exit 1
fi

command -v et >/dev/null 2>&1 || { log "et is not installed"; exit 1; }
nc -z 127.0.0.1 "$PORT" 2>/dev/null || { log "no etserver on 127.0.0.1:$PORT"; exit 1; }

log "=== attaching session '$SESSION' over the et transport"
# A named attach rather than discovery: this proves the control stream, without
# mirroring whatever else happens to be on the host's default tmux server.
# `cmux rpc` is the raw v2 call; a named attach avoids mirroring whatever else happens to
# be on the host's default tmux server.
#
# The etserver port goes in transport_port, not port. `port` is the ssh port, and one-shot
# discovery still rides ssh, so putting 2039 there sends ssh at the etserver and it answers
# with `kex_exchange_identification: Connection reset by peer`.
RESULT="$(cli rpc remote.tmux.attach \
  "{\"host\":\"$HOST\",\"session\":\"$SESSION\",\"transport\":\"et\",\"transport_port\":$PORT}" 2>&1)"
log "attach result: $(printf '%s' "$RESULT" | head -c 300)"

case "$RESULT" in
  *'"attached"'*) pass "the attach returned a result rather than an error" ;;
  *) fail "attach did not succeed: $(printf '%s' "$RESULT" | head -c 120)" ;;
esac

# The decisive evidence is the app's own view of the stream, not a process listing. A live
# process proves something was spawned; only these fields prove the control protocol crossed
# et and was understood — the two bugs this harness found both left a live process behind.
#
#   enter    the ESC P 1000 p handshake was parsed. cmux withholds commands until it arrives,
#            and et delivers it mid-line behind the login shell's echo.
#   windows  a real `list-windows` result came back over the stream and was applied.
# The transport and its port are part of the endpoint's identity, so a lookup that omits them
# addresses a different endpoint and quietly matches nothing — which reads as "the stream never
# reached control mode" rather than "you asked about the wrong connection".
state() {
  cli rpc remote.tmux.state \
    "{\"host\":\"$HOST\",\"session\":\"$SESSION\",\"transport\":\"et\",\"transport_port\":$PORT}"
}
stream_entered() { state | grep -q '"enter_received" : true'; }
stream_has_windows() { state | grep -qE '"window_count" : [1-9]'; }

if await "the control stream to reach control mode over et" 60 stream_entered; then
  pass "cmux parsed the control-mode handshake over et"
else
  fail "no control-mode handshake over et (enter_received stayed false)"
fi
if await "a window to arrive over the et-carried stream" 60 stream_has_windows; then
  pass "tmux windows arrived over the et-carried stream"
else
  fail "no windows arrived over the et-carried stream"
fi

# And the transport must be this host's et, under a pty: a bare pipe spawn is exactly what
# produces no output. Match the whole shape so another agent's `script` or `et` cannot pass
# this for us.
pty_wrapped_et() {
  pgrep -f "script -q /dev/null .*et -p $PORT .*$HOST" >/dev/null 2>&1
}
if pty_wrapped_et; then
  pass "this host's et was spawned under a pseudo-terminal"
else
  fail "no pty-wrapped et for $HOST:$PORT (et emits nothing on pipes)"
fi

log "=== $FAILURES failed check(s)"
exit "$FAILURES"
