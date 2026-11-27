#!/bin/bash
# ============================================================================
# Remote-tmux ATTACH-WAIT harness.
#
# Checks, through the real `cmux ssh-tmux` and a running app, that an attach over the
# shared connection waits for a transport that is still working and reports what
# happened when it stops:
#
#   refuse  the transport fails after a delay   -> the error arrives when it fails and
#                                                  carries the transport's own reason
#   hang    the transport never says anything   -> the attach ends at the login quiet
#                                                  limit, says so, and stops the transport
#   slow    the transport connects after 45 s   -> the attach succeeds (it used to give
#                                                  up at 30 s), with progress lines
#
# The delays are injected by a stand-in `ssh` that the app runs in place of the real
# one. It reads its instruction from a file on each call, then either fails, hangs, or
# hands over to the real ssh, so everything past the delay is a real connection to a
# real tmux.
#
# PREREQUISITES
#   - A tagged Debug app built and running WITH the stand-in ssh in its environment:
#       scripts/remote-tmux-attach-wait-harness.sh --print-ssh    # prints the path
#       open -g --env CMUX_REMOTE_TMUX_SSH_FOR_TESTING=<path> "<tagged app>"
#   - Both remote tmux betas on for that bundle id:
#       defaults write com.cmuxterm.app.debug.<tag> remoteTmux.beta.enabled -bool true
#       defaults write com.cmuxterm.app.debug.<tag> remoteTmux.multiplexer.beta.enabled -bool true
#   - A loopback ssh alias from `scripts/remote-tmux-fuzz-host.sh <name>`. Defaults to
#     `cmux-fuzzhost`; override with CMUX_WAIT_HOST.
#
# Usage: CMUX_TAG=<tag> scripts/remote-tmux-attach-wait-harness.sh [refuse|hang|slow ...]
# With no scenario named it runs all three. `hang` takes the full login quiet limit
# (300 s). Exit code is the number of failed scenarios (0 = all green).
# ============================================================================
set -uo pipefail

STATE="${CMUX_WAIT_STATE_DIR:-$HOME/Library/Caches/cmux/remote-tmux-attach-wait}"
FAKE_SSH="$STATE/ssh"
MODE_FILE="$STATE/mode"
CALLS="$STATE/calls"
HANG_PID="$STATE/hang.pid"

write_fake_ssh() {
  mkdir -p "$STATE"
  cat > "$FAKE_SSH" <<EOF
#!/bin/sh
# Stand-in ssh for scripts/remote-tmux-attach-wait-harness.sh. Reads its instruction on
# every call, so the harness changes behavior without relaunching the app.
mode="\$(cat "$MODE_FILE" 2>/dev/null)"
# Only the connection itself is slowed or broken. A control operation on a shared master
# (ssh -O ...) is cleanup, and making that hang would leave a process behind that the
# attach under test never started.
for arg in "\$@"; do
  [ "\$arg" = "-O" ] && mode="control"
done
echo "\$(date '+%H:%M:%S') pid=\$\$ mode=\${mode:-pass}" >> "$CALLS"
case "\$mode" in
  refuse:*)
    sleep "\${mode#refuse:}"
    echo 'ssh: connect to host injected.test port 22: Connection refused' >&2
    exit 255 ;;
  hang)
    echo \$\$ > "$HANG_PID"
    exec sleep 100000 ;;
  slow:*)
    sleep "\${mode#slow:}"
    exec /usr/bin/ssh "\$@" ;;
  *)
    exec /usr/bin/ssh "\$@" ;;
esac
EOF
  chmod 755 "$FAKE_SSH"
  touch "$CALLS"
}

if [ "${1:-}" = "--print-ssh" ]; then
  write_fake_ssh
  : > "$MODE_FILE"
  echo "$FAKE_SSH"
  exit 0
fi

TAG="${CMUX_TAG:?set CMUX_TAG=<tag> of a running tagged Debug app}"
HOST="${CMUX_WAIT_HOST:-cmux-fuzzhost}"
BUNDLE="com.cmuxterm.app.debug.$TAG"
CLI=(scripts/cmux-debug-cli.sh)
FAILURES=0

log()  { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
pass() { printf '  ✅ %s\n' "$*"; }
fail() { printf '  ❌ %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

cd "$(dirname "$0")/.." || exit 1
write_fake_ssh
: > "$MODE_FILE"

for key in remoteTmux.beta.enabled remoteTmux.multiplexer.beta.enabled; do
  if [ "$(defaults read "$BUNDLE" "$key" 2>/dev/null)" != "1" ]; then
    echo "$key is not on for $BUNDLE; this harness covers the shared-connection attach" >&2
    exit 2
  fi
done
if ! /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true >/dev/null 2>&1; then
  echo "cannot reach $HOST; start it with scripts/remote-tmux-fuzz-host.sh $HOST" >&2
  exit 2
fi

# Runs one attach with the stand-in in `mode`. Leaves the CLI's output in $OUT, its exit
# status in $STATUS and the seconds it took in $ELAPSED, and says whether the app went
# through the stand-in at all: an app launched without it would pass `slow` and fail the
# other two for the wrong reason.
attach() {
  local mode="$1" before start
  rm -f "$HANG_PID"
  printf '%s' "$mode" > "$MODE_FILE"
  before="$(wc -l < "$CALLS" 2>/dev/null || echo 0)"
  start="$(date +%s)"
  OUT="$(CMUX_QUIET=1 CMUX_TAG="$TAG" "${CLI[@]}" ssh-tmux "$HOST" 2>&1)"
  STATUS=$?
  ELAPSED=$(( $(date +%s) - start ))
  : > "$MODE_FILE"
  printf '%s\n' "$OUT" | sed 's/^/    | /'
  log "exit=$STATUS after ${ELAPSED}s"
  if [ "$(wc -l < "$CALLS" 2>/dev/null || echo 0)" -le "$before" ]; then
    fail "the app did not run the stand-in ssh; launch it with CMUX_REMOTE_TMUX_SSH_FOR_TESTING=$FAKE_SSH"
    return 1
  fi
}

scenario_refuse() {
  log "refuse: the transport fails 8 s in"
  attach "refuse:8" || return
  [ "$STATUS" -ne 0 ] && pass "the attach failed" || fail "the attach reported success"
  case "$OUT" in
    *"Connection refused"*) pass "the error carries the transport's own reason" ;;
    *) fail "the error does not say why the transport failed" ;;
  esac
  if [ "$ELAPSED" -ge 8 ] && [ "$ELAPSED" -lt 30 ]; then
    pass "it failed when the transport did (${ELAPSED}s), not at a time limit"
  else
    fail "it took ${ELAPSED}s; expected between 8 and 30"
  fi
}

scenario_hang() {
  log "hang: the transport never says anything (takes the 300 s login quiet limit)"
  attach "hang" || return
  [ "$STATUS" -ne 0 ] && pass "the attach failed" || fail "the attach reported success"
  case "$OUT" in
    *"still starting after"*) pass "the error says the connection stayed quiet while starting" ;;
    *) fail "the error does not name the quiet login" ;;
  esac
  case "$OUT" in
    *"still logging in"*) pass "progress lines were printed while it waited" ;;
    *) fail "no progress line was printed during the wait" ;;
  esac
  if [ "$ELAPSED" -ge 295 ] && [ "$ELAPSED" -lt 340 ]; then
    pass "it ended at the quiet limit (${ELAPSED}s)"
  else
    fail "it took ${ELAPSED}s; expected about 300"
  fi
  # The stand-in recorded its pid and became a sleep; a stopped attach must not leave it behind.
  local hung
  hung="$(cat "$HANG_PID" 2>/dev/null)"
  if [ -z "$hung" ]; then
    fail "the stand-in never recorded the hung transport's pid"
  elif kill -0 "$hung" 2>/dev/null; then
    fail "the transport (pid $hung) is still running after the attach gave up on it"
  else
    pass "the transport was stopped"
  fi
}

scenario_slow() {
  log "slow: the transport connects after 45 s"
  attach "slow:45" || return
  case "$OUT" in
    *"OK host=$HOST"*) pass "the attach succeeded" ;;
    *) fail "a login that took 45 s was not waited for" ;;
  esac
  case "$OUT" in
    *"still logging in"*) pass "progress lines were printed while it waited" ;;
    *) fail "no progress line was printed during the wait" ;;
  esac
  if [ "$ELAPSED" -ge 45 ]; then
    pass "it waited through the delay (${ELAPSED}s)"
  else
    fail "it returned after ${ELAPSED}s, before the transport could have connected"
  fi
}

SCENARIOS=("$@")
[ "${#SCENARIOS[@]}" -eq 0 ] && SCENARIOS=(refuse hang slow)
for scenario in "${SCENARIOS[@]}"; do
  case "$scenario" in
    refuse|hang|slow) "scenario_$scenario" ;;
    *) echo "unknown scenario: $scenario (refuse, hang or slow)" >&2; exit 2 ;;
  esac
done

log "failures: $FAILURES"
exit "$FAILURES"
