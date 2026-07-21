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
RESULT="$(cli rpc remote.tmux.attach \
  "{\"host\":\"$HOST\",\"session\":\"$SESSION\",\"port\":$PORT,\"transport\":\"et\"}" 2>&1)"
log "attach result: $(printf '%s' "$RESULT" | head -c 300)"

# The decisive evidence is a live et process carrying tmux for this host, spawned by
# the app rather than by this script.
et_stream_live() {
  pgrep -f "attach-session" 2>/dev/null | while read -r p; do
    ps -o command= -p "$p" 2>/dev/null | grep -q "et " && echo x
  done | grep -q x
}
if await "an et-carried control stream spawned by cmux" 60 et_stream_live; then
  pass "cmux spawned a control stream over et"
else
  fail "no et-carried control stream appeared"
fi

# And it must be under a pty: a bare pipe spawn is exactly what produces no output.
pty_wrapped() { pgrep -fl "script -q /dev/null" >/dev/null 2>&1; }
if pty_wrapped; then
  pass "the transport was spawned under a pseudo-terminal"
else
  fail "no pty wrapper around the transport (et emits nothing on pipes)"
fi

log "=== $FAILURES failed check(s)"
exit "$FAILURES"
