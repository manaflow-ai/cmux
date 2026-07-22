#!/bin/bash
# ============================================================================
# Remote-tmux RECONNECT-AUTH harness.
#
# Checks that a reconnect which cannot authenticate produces a login workspace,
# leaves the mirror parked (not torn down), resumes once auth succeeds, and opens
# at most one login per host.
#
# Hermetic: breaks a loopback sshd's authorized_keys on demand, so no 2FA host,
# no network changes. Same isolation contract as the render harness.
#
# PREREQUISITES
#   - A tagged Debug app built AND RUNNING; run with CMUX_TAG=<tag>.
#   - remote-tmux beta on for that bundle id (a fresh tagged build defaults OFF):
#       defaults write com.cmuxterm.app.debug.<tag> remoteTmux.beta.enabled -bool true
#   - A loopback ssh alias whose sshd this script may break, created by
#     `scripts/remote-tmux-fuzz-host.sh <name>`. Defaults to `cmux-fuzzhost`;
#     override with CMUX_AUTH_HOST / CMUX_AUTH_SSHD_DIR.
#
# Exit code is the number of failed scenarios (0 = all green).
# ============================================================================
set -uo pipefail

TAG="${CMUX_TAG:?set CMUX_TAG=<tag> of a running tagged Debug app}"
HOST="${CMUX_AUTH_HOST:-cmux-fuzzhost}"
SSHD_DIR="${CMUX_AUTH_SSHD_DIR:-$HOME/Library/Caches/cmux/remote-tmux-fuzz/${HOST}-sshd}"
AUTH="$SSHD_DIR/authorized_keys"
CLI=(scripts/cmux-debug-cli.sh)
FAILURES=0

log()  { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
pass() { printf '  ✅ %s\n' "$*"; }
fail() { printf '  ❌ %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

cli() { CMUX_QUIET=1 CMUX_TAG="$TAG" "${CLI[@]}" "$@" 2>&1; }

# Workspaces as `<ref>\t<title>`. The plain text listing decorates the selected row
# with `* ` and `[selected]`, so comparing raw lines reports an untouched workspace as
# deleted the moment selection moves. Key on the ref instead, which is stable.
workspaces() {
  cli list-workspaces --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in d.get("workspaces", []):
    print("%s\t%s" % (w.get("ref", ""), w.get("title") or ""))
'
}

# The login workspace is titled from a localized format ("Sign in to %@"), so match on
# the destination plus a sign-in marker rather than the whole English string.
login_refs() { workspaces | grep -iE "sign.?in.*${HOST}" | cut -f1 | sort; }
login_tab_present() { [ -n "$(login_refs)" ]; }
login_absent() { [ -z "$(login_refs)" ]; }

# The tmux sessions actually running on the host. `workspace.list` does not mark which
# workspaces are remote-tmux mirrors (its `remote` block stays empty for them), so the
# mirror is identified by matching titles against these names.
host_sessions() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" \
    'tmux list-sessions -F "#{session_name}" 2>/dev/null' 2>/dev/null | sort
}

# Refs of the workspaces mirroring this host's sessions. Matching happens in python
# because the session list is newline-separated and `awk -v` cannot carry newlines.
mirror_refs() {
  # Exported, not prefixed: a `VAR=x cmd | python3` assignment reaches only the left
  # side of the pipe, so the matcher would silently see an empty set and match nothing.
  export CMUX_HOST_SESSIONS="$HOST_SESSIONS"
  cli list-workspaces --json 2>/dev/null | python3 -c '
import json, os, sys
want = {s for s in os.environ.get("CMUX_HOST_SESSIONS", "").split("\n") if s}
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in d.get("workspaces", []):
    if (w.get("title") or "") in want:
        print(w.get("ref", ""))
' | sort
}

# Baseline captured once the mirror is settled. Checks are differential against it
# rather than "are there at least N workspaces": the app under test may already have
# unrelated workspaces open, so a count threshold would be satisfied without any mirror
# existing — the check would pass while the feature was completely broken.
MIRROR_BASELINE=""

# Every one of the host's sessions has a workspace, AND a control stream is running for
# it. Waiting only for workspaces to appear races the attach burst: workspaces are
# created before their streams finish connecting, so breaking auth at that moment tests
# a half-built mirror instead of a reconnect.
mirror_settled() {
  local want have streams need_streams
  want="$(printf '%s\n' "$HOST_SESSIONS" | grep -c .)"
  have="$(mirror_refs | grep -c .)"
  streams="$(control_stream_pids | grep -c .)"
  # With two or more sessions, demand two live streams. The "exactly one login for several
  # dropped sessions" check is only meaningful if several streams actually drop, and the
  # fuzz sshd sets `MaxSessions 1`, so a single stream is a real possibility. Requiring it
  # here means that case times out and says so instead of reporting a green guard that was
  # never exercised.
  need_streams=1
  [ "$want" -ge 2 ] && need_streams=2
  [ "$have" -ge "$want" ] && [ "$streams" -ge "$need_streams" ]
}

# Every workspace the mirror contributed is still present. This is criterion 2: the
# connection parked instead of ending, so nothing was torn down.
mirror_intact() {
  local missing
  missing="$(comm -23 <(printf '%s\n' "$MIRROR_BASELINE") <(mirror_refs))"
  [ -z "$missing" ] || {
    log "mirrored workspaces that disappeared: $(printf '%s' "$missing" | tr '\n' ' ')"
    return 1
  }
}

# Wait on a condition, not a duration.
await() {
  local what="$1" timeout="$2"; shift 2
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$@"; then return 0; fi
    sleep 1
  done
  log "timed out after ${timeout}s waiting for: $what"
  return 1
}

restore_auth() { [ -f "$AUTH.off" ] && mv "$AUTH.off" "$AUTH"; }

# A retry has reached the sshd since SSHD_BEFORE was sampled. The checks below wait on this
# instead of sleeping out the worst-case backoff: the failed attempt IS the auth-required
# report, so once it has happened the question they ask is already answerable.
sshd_retried() { [ "$(sshd_log_lines)" -gt "${SSHD_BEFORE:-0}" ]; }

# Lines in the loopback sshd's log. Every reconnect attempt reaches that sshd and is logged
# even when it fails authentication, so a growing count is direct evidence the connection is
# still retrying. Without this, "no login reappeared" is equally true of a stranded host that
# is doing nothing at all — which is how a strand shipped once already.
sshd_log_lines() { wc -l < "$SSHD_DIR/sshd.log" 2>/dev/null | tr -d ' '; }
# A private work dir rather than fixed /tmp paths: a hardcoded name is pre-creatable by anyone
# on the box, so the stderr this harness reads back to explain a failure could be another
# process's file, or a symlink pointing at something of mine. Also survives two runs at once.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-reconnect-auth.XXXXXX")" || exit 1
cleanup() { restore_auth; rm -rf "$WORKDIR"; }
trap cleanup EXIT

control_path() { ls "$HOME"/.cmux/ssh/tmux-*"$(printf '%s' "$HOST" | tr -c 'a-z0-9' '-')"*.sock 2>/dev/null | head -1; }

# The local `ssh` processes carrying a control stream for this host. The remote command
# is a `/bin/sh` resolver script, so the argv does NOT contain a literal "tmux -CC" —
# matching that finds nothing and a kill built on it silently does nothing. Match what
# is really there: the tmux subcommand the resolver forwards, plus the destination.
control_stream_pids() { pgrep -f "attach-session" 2>/dev/null | while read -r p; do
    ps -o command= -p "$p" 2>/dev/null | grep -q -- "$HOST" && printf '%s\n' "$p"
  done; }

drop_stream_unauthenticated() {
  # Order matters: master gone means the reconnect must authenticate from scratch,
  # and with authorized_keys moved aside that authentication fails.
  mv "$AUTH" "$AUTH.off" || return 1
  [ -n "$CMUX_CP" ] && ssh -O exit -o ControlPath="$CMUX_CP" "$HOST" >/dev/null 2>&1
  local pids; pids="$(control_stream_pids)"
  if [ -z "$pids" ]; then
    log "no control-stream process matched — the kill would be a no-op, so the drop is not real"
    return 1
  fi
  log "killing control stream pid(s): $(printf '%s' "$pids" | tr '\n' ' ')"
  # No `xargs -r`: it is a GNU extension that older BSD xargs rejects outright, and the
  # empty case is already handled above. Piping also avoids zsh's lack of word splitting.
  printf '%s\n' "$pids" | xargs kill
  return 0
}

cd "$(dirname "$0")/.." || exit 1
[ -f "$AUTH" ] || {
  log "no authorized_keys at $AUTH"
  log "run: scripts/remote-tmux-fuzz-host.sh $HOST"
  exit 1
}

# The app's control socket appears a little after launch, and later under load. Waiting for
# it here means a slow start reports itself, instead of surfacing as "mirror never settled"
# and looking like a failure of the code under test.
app_socket_ready() { cli list-workspaces >/dev/null 2>&1; }
if ! await "the app's control socket" 120 app_socket_ready; then
  log "no response on the tagged app socket for CMUX_TAG=$TAG"
  log "is the tagged app running? scripts/reload.sh --tag $TAG --launch"
  exit 1
fi

log "=== scenario 1: a reconnect that cannot authenticate offers a login"
# Two sessions on the host, so the mirror runs two control streams. Both drop together,
# so scenario 3's "one login per host" guard is actually exercised; with a single
# session it would pass no matter what the guard did.
ssh -o BatchMode=yes "$HOST" 'tmux new-session -d -s harness-a 2>/dev/null; tmux new-session -d -s harness-b 2>/dev/null; true' >/dev/null 2>&1
HOST_SESSIONS="$(host_sessions)"
SESSION_COUNT="$(printf '%s\n' "$HOST_SESSIONS" | grep -c .)"
log "host sessions to mirror ($SESSION_COUNT): $(printf '%s' "$HOST_SESSIONS" | tr '\n' ' ')"
[ "$SESSION_COUNT" -ge 2 ] || log "WARNING: fewer than 2 sessions; the per-host login guard is not being exercised"

cli ssh-tmux "$HOST" >/dev/null
if ! await "every session mirrored and its control stream live" 90 mirror_settled; then
  fail "mirror never settled — cannot test the reconnect path"
  exit "$FAILURES"
fi
MIRROR_BASELINE="$(mirror_refs)"
pass "mirror settled ($(printf '%s\n' "$MIRROR_BASELINE" | grep -c .) workspaces for $SESSION_COUNT sessions)"

# Capture cmux's own ControlPath while the socket still exists. `ssh -O exit` removes
# it, and the resume hinges on a master appearing at THIS exact path — cmux probes its
# own socket, so a master opened anywhere else is invisible to it.
CMUX_CP="$(control_path)"
if [ -z "$CMUX_CP" ]; then
  fail "could not find cmux's ssh ControlPath — cannot verify the resume"
  exit "$FAILURES"
fi
log "cmux ControlPath: $CMUX_CP"

drop_stream_unauthenticated || { fail "could not break auth"; exit "$FAILURES"; }
if await "a login workspace" 90 login_tab_present; then
  LOGIN_REFS="$(login_refs)"
  pass "login workspace appeared: $(printf '%s' "$LOGIN_REFS" | tr '\n' ' ')"
else
  LOGIN_REFS=""
  fail "no login workspace — the auth event reached no consumer on this mirror path"
fi

# Checked here, while the login is still the live offer. Several sessions dropped at
# once, so this is where a per-session (rather than per-host) offer would show up as
# duplicate tabs.
LOGIN_COUNT="$(printf '%s\n' "$LOGIN_REFS" | grep -c .)"
if [ "$LOGIN_COUNT" -eq 1 ]; then
  pass "exactly one login workspace for $SESSION_COUNT dropped sessions"
else
  fail "$LOGIN_COUNT login workspaces for $SESSION_COUNT dropped sessions (expected exactly 1)"
fi

if mirror_intact; then
  pass "every mirrored workspace survived while parked (nothing torn down)"
else
  fail "mirrored workspaces disappeared — the connection ended instead of parking"
fi

log "=== scenario 2: dismissing the login means no, and it sticks"
# The previous version of this asserted the opposite — that a fresh login appears after a
# dismissal — and it passed. That behavior is what made the close button useless: the retry
# that follows fails the same way, so the tab reopened immediately. What must happen instead
# is that the retrying continues quietly and no new login is offered for this outage.
if [ -z "$LOGIN_REFS" ]; then
  fail "no login workspace to dismiss — cannot check the dismissal"
else
  for ref in $LOGIN_REFS; do cli close-workspace --workspace "$ref" >/dev/null; done
  if ! await "the login workspace to close" 30 login_absent; then
    fail "the login workspace would not close; the rest of this scenario is meaningless"
  else
    # Wait for the retry to reach the sshd rather than sleeping out the worst-case backoff.
    # That failed attempt is the auth-required report, i.e. the exact moment the old behavior
    # reopened a tab, so both halves of the requirement become answerable as soon as it lands.
    SSHD_BEFORE="$(sshd_log_lines)"
    if await "the connection to retry after the dismissal" 60 sshd_retried; then
      pass "the connection kept retrying after the dismissal (sshd log $SSHD_BEFORE -> $(sshd_log_lines))"
      # Short settle for the app's turn between the ssh exit and a workspace appearing.
      sleep 3
      if login_tab_present; then
        fail "a login reappeared after being dismissed; closing it does not stick"
      else
        pass "no login reappeared after dismissal"
      fi
    else
      fail "no reconnect attempts after the dismissal — the host is stranded until restart"
    fi
  fi
  if mirror_intact; then
    pass "mirrored workspaces survived the dismissal"
  else
    fail "mirrored workspaces were lost when the login was dismissed"
  fi
fi

log "=== scenario 3: completing the login resumes the mirror"
restore_auth
# Stand in for the user finishing the login: open the shared master at cmux's own
# ControlPath, which is what the login pane's `ssh` invocation does. cmux probes its own
# socket, so a master opened anywhere else would be invisible to it.
master_open_attempt() {
  ssh -o ControlMaster=auto -o ControlPath="$CMUX_CP" \
      -o ControlPersist=2m -n -T "$HOST" true 2>"$WORKDIR/master-open.err"
  ssh -O check -o ControlPath="$CMUX_CP" "$HOST" >/dev/null 2>&1
}
# Retried, not one-shot: this runs immediately after auth is restored, and a single
# attempt that loses its stderr turns any transient refusal into an unexplained failure.
if ! await "a master at cmux's ControlPath (standing in for the user's login)" 30 master_open_attempt; then
  fail "could not open a master at cmux's ControlPath — the resume cannot be tested"
  log "last ssh stderr: $(tr '\n' ' ' < "$WORKDIR/master-open.err" 2>/dev/null)"
  exit "$FAILURES"
fi

# Resumption means cmux spawned a NEW control stream. Checking the master itself would
# be vacuous, since this script just opened it.
stream_respawned() { [ -n "$(control_stream_pids)" ]; }
if await "cmux to spawn a new control stream (mirror resumed)" 150 stream_respawned; then
  pass "mirror resumed: a new control stream is live"
else
  fail "mirror never resumed after authentication (no new control stream)"
fi

if mirror_intact; then
  pass "mirrored workspaces still intact after the resume"
else
  fail "mirrored workspaces were lost across the resume"
fi

log "=== scenario 4: a new outage offers again, and reconnecting closes that login"
# Two things at once, and both need the reconnect from scenario 3 to have happened: the
# dismissal from scenario 2 must no longer be in force (a reconnect ends the outage it
# applied to), and the login cmux opens must close by itself once the host is back. Checking
# the close on the scenario-2 login would prove nothing, since the user closed that one.
if ! drop_stream_unauthenticated; then
  fail "could not break auth for the second outage"
else
  if await "a login for the second outage" 120 login_tab_present; then
    pass "a new outage offers a login again (the dismissal applied only to the last one)"
    SECOND_LOGIN="$(login_refs)"
  else
    SECOND_LOGIN=""
    fail "no login for a new outage — the dismissal outlived the outage it was for"
  fi
  restore_auth
  if [ -n "$SECOND_LOGIN" ]; then
    await "a master for the second login" 30 master_open_attempt >/dev/null || true
    if await "cmux to close the login once the host is back" 120 login_absent; then
      pass "the login closed once the host reconnected"
    else
      fail "the login is still open after the host reconnected; a flap would stack more"
    fi
  fi
fi

log "=== scenario 5: a live connection is never asked to authenticate again"
# The straggler case, and the one the user actually hit: several sessions park, the user signs
# in, the first to reconnect releases the offer, and a sibling still finishing its pre-login
# attempt reports auth-required into an empty slot. The symptom is a second "Sign in to ..."
# tab appearing moments AFTER a successful sign-in.
#
# Reproduced by breaking auth again while a mirror for the host is still connected: any
# auth-required that arrives now must be swallowed, because a live connection proves
# authentication is not the blocker.
if ! mirror_settled; then
  log "mirror is not settled; skipping (nothing to contradict)"
else
  mv "$AUTH" "$AUTH.off" 2>/dev/null
  # Kill only ONE stream, so at least one connection for the host stays live.
  ONE="$(control_stream_pids | head -1)"
  if [ -z "$ONE" ]; then
    fail "no control stream to drop for the straggler check"
  else
    log "dropping one stream ($ONE) while others stay connected"
    SSHD_BEFORE="$(sshd_log_lines)"
    kill "$ONE" 2>/dev/null
    # The dropped stream's retry reaching sshd is its auth-required report. Waiting for that
    # edge, rather than a fixed 40s, means a failure here says the straggler case was never
    # exercised instead of passing vacuously.
    if await "the dropped stream to retry" 60 sshd_retried; then
      sleep 3
      if login_tab_present; then
        fail "a login appeared while the host still had a live connection"
      else
        pass "no login offered while a connection to the host was live"
      fi
    else
      fail "no reconnect attempt reached sshd, so the straggler case was never exercised"
    fi
  fi
  restore_auth
fi

log "=== teardown: leave the mirror connected"
# A run that exits with the mirrors still parked poisons the next run, which then reports
# "mirror never settled" for a reason that has nothing to do with the code under test.
# Restoring authorized_keys is not enough on its own: the parked connections already failed
# their ssh and nothing reopens the master for them.
restore_auth
for ref in $(login_refs); do cli close-workspace --workspace "$ref" >/dev/null; done
await "a master for the teardown resume" 30 master_open_attempt >/dev/null || true
if await "the mirror to reconnect before exiting" 120 mirror_settled; then
  log "mirror reconnected; the app is ready for another run"
else
  log "WARNING: mirror did not reconnect — the next run may need a relaunch"
fi

log "=== $FAILURES failed scenario(s)"
exit "$FAILURES"
