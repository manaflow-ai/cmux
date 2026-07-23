#!/bin/bash
# ============================================================================
# Proves that remote-tmux-et-conformance.sh can FAIL.
#
# A conformance harness that only ever reports success is worthless, and worse than worthless
# because its output looks like evidence. Every wrong result this project produced came from a
# check whose success condition had a second, cheaper way to become true: stale text on a screen,
# the harness's own echoed command, a half-flushed buffer, its own nonce tag. Reading the code
# cannot rule that out. Only driving each check to both outcomes can.
#
# So this runs the real harness, unmodified, through its own brokered interface, against substitute
# brokers whose behaviour is decided in advance. Each scenario breaks exactly one property, and the
# oracle below states what the harness is supposed to say about it. A scenario whose verdict does
# not move is a check that is not discriminating, and this exits non-zero.
#
# It also asserts coverage: every check must be seen reporting more than one outcome across the
# matrix. A check that says PASS in all eight scenarios has been shown to be inert.
#
# No authentication, no network, no key presses. Runs against a private tmux socket directory and
# never touches the default server.
#
# Usage: scripts/remote-tmux-et-conformance-selftest.sh
# Exit code is the number of oracle mismatches (0 = the harness discriminates everywhere).
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

HARNESS=scripts/remote-tmux-et-conformance.sh
[ -x "$HARNESS" ] || [ -f "$HARNESS" ] || { echo "cannot find $HARNESS" >&2; exit 2; }

WORK="$(mktemp -d /tmp/cmux-etconf-selftest.XXXXXX)" || exit 1
# /tmp deliberately, and short: a unix socket path is capped near 104 bytes and macOS sets TMPDIR
# to a long /var/folders/... path. Putting a tmux socket under it fails to bind with "File name
# too long", which the harness then reports as three unrelated transport failures.
trap 'rm -rf "$WORK"' EXIT

REAL_TMUX="$(command -v tmux || echo /opt/homebrew/bin/tmux)"
MISMATCHES=0
declare -a COVERAGE

ok()   { printf '  ok        %-12s %-26s %s\n' "$1" "$2" "$3"; }
bad()  { printf '  MISMATCH  %-12s %-26s %s\n' "$1" "$2" "$3"; MISMATCHES=$((MISMATCHES + 1)); }
head2() { printf '\n--- scenario %s: %s\n' "$1" "$2"; }

# ---------------------------------------------------------------------------
# The substitute brokers. Each takes the real broker's argv shape
# (-et -fallback <host> -c <command>) and misbehaves in exactly one way.
# ---------------------------------------------------------------------------
make_fake() {
  local name="$1" body="$2"
  local f="$WORK/fake-$name"
  {
    echo '#!/bin/bash'
    echo '# Substitute broker. Same argv shape as the real one; one property deliberately broken.'
    echo 'CMD="${!#}"'
    echo "export TMUX_TMPDIR=\"$WORK/remote-$name\""
    echo 'mkdir -p "$TMUX_TMPDIR"'
    echo 'unset TMUX'
    echo "$body"
  } > "$f"
  chmod +x "$f"
  printf '%s' "$f"
}

# Everything works. The command really runs, including a real local tmux on a private socket, so
# the handshake, %begin/%end and the session are genuine protocol bytes rather than canned text.
FAKE_GOOD=$(make_fake good 'eval "$CMD"')

# Ignores -c entirely: connects, prints a prompt, runs nothing.
FAKE_NOFWD=$(make_fake nofwd 'printf "[fake]~%% \n"')

# Runs the command with tmux absent from PATH — and ONLY tmux.
#
# This used to set PATH=/nonexistent, which also removed the coreutils the harness's precondition
# gate needs (it verifies delivery with `wc -c | tr`), so the gate failed and the login-shell check
# was never reached. A substitute has to break exactly one property; breaking the shell as well
# tests nothing. /usr/bin:/bin has wc and tr but not tmux, which lives under /opt/homebrew/bin here.
FAKE_NOLOGIN=$(make_fake nologin 'PATH=/usr/bin:/bin; export PATH; eval "$CMD" 2>&1')

# Truncates any command longer than 600 bytes, the way a canonical-mode pty does. The harness is
# never told 600; it has to find it.
FAKE_LIMIT=$(make_fake limit '
if [ ${#CMD} -gt 600 ]; then printf "%s" "${CMD:0:600}"; printf "\n"; exit 0; fi
eval "$CMD"')

# Reaches a shell but never enters control mode. Done with a stub `tmux` earlier on PATH rather
# than by filtering output through sed: a pipe would replace the tty, which breaks more than the
# one property this scenario is meant to break.
mkdir -p "$WORK/bin-noctrl"
cat > "$WORK/bin-noctrl/tmux" <<'STUB'
#!/bin/bash
# A tmux that refuses control mode, the way a version mismatch or a bad socket would.
echo "open terminal failed: not a terminal" >&2
exit 1
STUB
chmod +x "$WORK/bin-noctrl/tmux"
FAKE_NOCTRL=$(make_fake noctrl "PATH=\"$WORK/bin-noctrl:\$PATH\"; export PATH; eval \"\$CMD\"")

# Enters control mode but never carries the payload. The stub emits a genuine handshake and a real
# %begin/%end block, so the handshake check must still pass while the payload check must fail —
# which is the discrimination this scenario exists to prove.
mkdir -p "$WORK/bin-noreply"
cat > "$WORK/bin-noreply/tmux" <<'STUB'
#!/bin/bash
# Handshake and command replies, but the session's own output never arrives.
printf '\033P1000p'
printf '%%begin 1 1 0\r\n%%end 1 1 0\r\n'
printf '%%window-add @9\r\n%%session-changed $1 stub\r\n'
sleep 1
printf '%%exit\r\n\033\\'
exit 0
STUB
chmod +x "$WORK/bin-noreply/tmux"
FAKE_NOREPLY=$(make_fake noreply "PATH=\"$WORK/bin-noreply:\$PATH\"; export PATH; eval \"\$CMD\"")

# The session does not outlive its client — a transport that tears the session down on exit.
#
# Two things this has to get right, both learned by getting them wrong. The harness's command uses
# `exec`, which would replace this shell and mean the teardown below never runs at all, so `exec`
# is stripped first. And the teardown must target the socket the SESSION is on, not this
# substitute's own: the harness passes TMUX_TMPDIR inside the command, and because that runs under
# `eval` in this shell, the assignment is inherited here — so no second guess is needed.
FAKE_NOSURVIVE=$(make_fake nosurvive "
CMD=\"\${CMD/exec /}\"
eval \"\$CMD\"
rc=\$?
$REAL_TMUX kill-server 2>/dev/null
exit \$rc")


# A substitute that DEMANDS A PASSWORD on the terminal and reads it back.
#
# This is the arm that was missing all along, and its absence is why the oracle passed while the
# real interactive path was broken four different ways. Every other substitute answers instantly and
# reads no input, so nothing here ever exercised the one property a 2FA transport depends on: that
# the prompt reaches a terminal and the answer gets back. A wrapper that captures stdout, pipes it,
# or fails to relay stdin passes every non-prompting scenario and hangs on this one.
mkdir -p "$WORK/prompting"
cat > "$WORK/fake-prompting" <<'PROMPT_EOF'
#!/bin/bash
CMD="${!#}"
export TMUX_TMPDIR="$WORK_PROMPT_TMUX"; mkdir -p "$TMUX_TMPDIR"; unset TMUX
printf '(tester@fakehost) two-factor login for tester\n\nEnter a passcode:\n'
printf 'Passcode: '
# Refuses to proceed without an answer, exactly like the real thing. A caller whose wrapper does not
# relay stdin gets nothing here and hangs until its timeout — which is the failure being tested for.
if ! IFS= read -r -t 60 answer; then
  printf '\nNO_PASSCODE_RECEIVED\n'; exit 3
fi
printf '\n[tester@fakehost]~%% %s; exit\n' "$CMD"
eval "$CMD" 2>&1
printf '\nSession terminated\n'
PROMPT_EOF
chmod +x "$WORK/fake-prompting"
export WORK_PROMPT_TMUX="$WORK/prompting-tmux"
FAKE_PROMPTING="$WORK/fake-prompting"
# ---------------------------------------------------------------------------
# Run the real harness against one substitute and return its output.
# ---------------------------------------------------------------------------
run_against() {
  local fake="$1"
  # A substitute receives its command as argv, so no tty line discipline applies to it. Declaring
  # that keeps the harness from reporting a missing bound as a finding against a healthy transport.
  local no_limit="${2:-}"
  # Separate statements on purpose: within a single `local`, an earlier name is not reliably
  # visible to a later initializer, and under `set -u` that made every scenario write to the same
  # clobbered log file.
  local log="$WORK/out-$(basename "$fake")"
  TRANSPORT_BROKER="$fake" \
  TRANSPORT_BROKER_ARGS="-et -fallback" \
  TRANSPORT_HOST="selftest" \
  NO_LINE_LIMIT="$no_limit" \
  HUMAN_GRACE=2 \
  CMUX_ET_PORT=0 \
  BISECT_SAMPLES=fine \
  RESULTS="$WORK/results-$(basename "$fake").txt" \
    timeout 300 bash "$HARNESS" > "$log" 2>&1
  printf '%s' "$log"
}

# An expectation: the harness's output must (or must not) contain a pattern.
# Record which way the harness actually ruled on a check, so coverage compares outcomes rather
# than "did my expectation match" — two different expectations both matching is not two outcomes.
record_verdict() {
  local check="$1" scenario="$2" log="$3" marker="$4" verdict=absent
  # `.*` between the tick and the marker: the harness's wording sometimes has a word in
  # between ("✅ the session outlived …"), and requiring the marker to follow the tick
  # immediately made a check that plainly discriminates look inert.
  if grep -aqE -- "✅ .*$marker" "$log"; then verdict=pass
  elif grep -aqE -- "❌ .*$marker" "$log"; then verdict=fail
  fi
  COVERAGE+=("$check|$scenario|$verdict")
}

expect() {
  local scenario="$1" check="$2" mode="$3" pattern="$4" log="$5"
  local found=no
  grep -aqE -- "$pattern" "$log" && found=yes
  if [ "$mode" = present ] && [ "$found" = yes ]; then
    ok "$scenario" "$check" "reported as expected"
  elif [ "$mode" = absent ] && [ "$found" = no ]; then
    ok "$scenario" "$check" "correctly not reported"
  else
    bad "$scenario" "$check" "wanted $mode /$pattern/, log: $log"
  fi
}

echo "=== proving the conformance harness discriminates"
echo "    harness: $HARNESS"
echo "    no auth, no network, private tmux socket dir under $WORK"

# --- 1. Everything healthy: the harness must pass the checks it can judge.
head2 good "nothing broken — the harness should find nothing wrong"
LOG=$(run_against "$FAKE_GOOD" no-line-limit)
expect good login-shell     present '✅ a login shell resolves tmux' "$LOG"
record_verdict login-shell good "$LOG" '(a login shell resolves tmux|tmux did not resolve)'
record_verdict control-mode good "$LOG" '(control mode entered|no %begin over this transport)'
record_verdict stream-answers good "$LOG" '(real data crossed|nothing but the handshake)' 
expect good control-mode    present '✅ control mode entered' "$LOG"
expect good stream-answers  present '✅ real data crossed the control stream' "$LOG"
# A healthy transport must produce a clean run. Without this the oracle reported "ok" for a run
# whose summary said "1 failed check(s)", so any regression that makes the harness red against a
# good transport was invisible. The substitute takes its command as argv rather than typing it into
# a pty, so it genuinely has no canonical-line bound; that is out of scope for it, and the harness
# is told so with NO_LINE_LIMIT rather than being left to invent a finding.
expect good clean-run       present '0 failed check\(s\)' "$LOG"
# survival is skipped in brokered mode; nothing to record
# record_verdict survival good "$LOG" '(session survives the transport dying|session outlived the clients|session did not outlive)' 

# --- 2. The precondition gate. This is the check that stops the harness inventing findings.
head2 nofwd "the broker ignores -c, so nothing runs"
LOG=$(run_against "$FAKE_NOFWD" no-line-limit)
expect nofwd precondition   present 'PRECONDITION FAILED' "$LOG"
# And it must NOT go on to judge individual claims about a transport that never worked.
# Anchored on the claim HEADER, not on a verdict's wording. The previous pattern looked for
# "(✅|❌) a login shell resolves tmux", but the negative verdict reads "❌ tmux did not resolve in
# the remote shell", so the pattern could never match and the check passed whether or not the
# harness had gone on to judge a dead transport. The header is printed before any verdict in that
# section, so its absence is what actually proves nothing was judged.
expect nofwd no-false-claims absent  'claim: the remote command runs in a LOGIN shell' "$LOG"
expect nofwd no-verdicts-at-all absent '(✅|❌)' "$LOG"

# --- 3. tmux missing from PATH.
head2 nologin "the remote shell has no tmux on PATH"
LOG=$(run_against "$FAKE_NOLOGIN" no-line-limit)
expect nologin login-shell  present '❌ tmux did not resolve' "$LOG"
record_verdict login-shell nologin "$LOG" '(a login shell resolves tmux|tmux did not resolve)' 

# --- 4. A 600-byte limit the harness was never told about.
head2 limit "commands over 600 bytes are truncated; the harness must find that number"
LOG=$(run_against "$FAKE_LIMIT")
expect limit length-bound   present 'the length bound is real' "$LOG"
# The bracket must contain 600, and cmux's 1024 budget must be reported as not fitting.
if grep -aq 'delivery stops between' "$LOG"; then
  LO=$(sed -n 's/.*delivery stops between \([0-9]*\) and \([0-9]*\).*/\1/p' "$LOG" | head -1)
  HI=$(sed -n 's/.*delivery stops between \([0-9]*\) and \([0-9]*\).*/\2/p' "$LOG" | head -1)
  if [ -n "$LO" ] && [ -n "$HI" ] && [ "$LO" -le 600 ] && [ "$HI" -ge 600 ]; then
    ok limit length-threshold "bracketed 600 as [$LO,$HI] without being told"
  else
    bad limit length-threshold "bracket [${LO:-?},${HI:-?}] does not contain 600"
  fi
else
  bad limit length-threshold "no bracket reported at all"
fi
expect limit budget-too-big present 'commands will be truncated' "$LOG"

# --- 5. Control mode never reached.
head2 noctrl "the handshake and protocol lines never arrive"
LOG=$(run_against "$FAKE_NOCTRL" no-line-limit)
expect noctrl control-mode  present '❌ no %begin over this transport' "$LOG"
record_verdict control-mode noctrl "$LOG" '(control mode entered|no %begin over this transport)' 

# --- 6. Handshake fine, payload never carried.
head2 noreply "control mode comes up but carries no data"
LOG=$(run_against "$FAKE_NOREPLY" no-line-limit)
expect noreply stream-answers present '❌ nothing but the handshake crossed the stream' "$LOG"
record_verdict stream-answers noreply "$LOG" '(real data crossed|nothing but the handshake)' 

# --- 7. Session dies with its client.
head2 nosurvive "the session does not outlive the transport"
LOG=$(run_against "$FAKE_NOSURVIVE" no-line-limit)
# Deliberately no expectation here any more. The harness now SKIPS survival in brokered mode,
# because the old check only asked whether the harness's own local session still existed — nothing
# in brokered mode ever tries to remove it, so it passed even when control mode was never reached.
# This oracle drives brokered mode only, so it cannot exercise the honest version, and asserting
# the old wording would be asserting a verdict the harness correctly declines to give.
expect nosurvive survival-skipped present 'not checked in brokered mode: nothing here ends the stream' "$LOG"
# survival is skipped in brokered mode; nothing to record
# record_verdict survival nosurvive "$LOG" '(session survives the transport dying|session outlived the clients|session did not outlive)' 

# ---------------------------------------------------------------------------
# Coverage: a check that answered the same way everywhere has not been shown to discriminate.
# ---------------------------------------------------------------------------
echo ""
echo "--- can each check report more than one outcome?"
for check in login-shell control-mode stream-answers; do
  distinct=$(printf '%s\n' "${COVERAGE[@]}" | awk -F'|' -v c="$check" '$1==c {print $3}' | sort -u | tr '\n' ' ')
  count=$(printf '%s\n' "${COVERAGE[@]}" | awk -F'|' -v c="$check" '$1==c {print $3}' | sort -u | wc -l | tr -d ' ')
  if [ "$count" -ge 2 ]; then
    ok coverage "$check" "seen both ways: $distinct"
  else
    bad coverage "$check" "only ever reported '$distinct' — not shown to discriminate"
  fi
done

# ---------------------------------------------------------------------------
# Declare what this oracle CANNOT exercise. A summary that says PASS while silently skipping a
# check reads as full coverage, which is the same dishonesty the harness itself was fixed for.
# ---------------------------------------------------------------------------
echo ""
echo "--- checks this oracle does NOT exercise, so they remain unproven here"
echo "  pty / -N        the harness skips this check in brokered mode, because on a broker a failed"
echo "                  connection and a silent one look identical. It is only exercised on the"
echo "                  loopback path, where it currently passes but has no substitute that would"
echo "                  make it fail. To close this, the oracle needs a loopback-mode arm with a"
echo "                  stand-in et that honours -N."
echo "  argv rejection  depends on the client's own wording; the real et here IGNORES an unknown"
echo "                  flag, so the harness skips rather than asserts. No substitute drives it."
echo "  MAX_CANON probe the host-reported figure is a cross-check only; no scenario forces a"
echo "                  disagreement between it and the measured bound."

echo ""
if [ "$MISMATCHES" -eq 0 ]; then
  echo "=== SELF-TEST PASS: every scenario moved the verdict the oracle predicted."
  echo "    Coverage is PARTIAL and deliberately stated as such. Shown to report both outcomes:"
  echo "      login-shell, control-mode, stream-answers — 3 of the harness's checks."
  echo "    Driven in one direction only, so their other branch is unproven:"
  echo "      the precondition gate (fail only), short-command delivery (pass only),"
  echo "      length-bound-real and cmux-budget-fits (the budget check's PASS branch fires in"
  echo "      no scenario: limit exercises only its failure, and good short-circuits earlier),"
  echo "      the DCS position, which is reported rather than asserted, and survival, which the"
  echo "      harness skips in brokered mode and only the loopback path can observe."
  echo "    The earlier wording — \"every scenario moved the verdict it was supposed to move\" —"
  echo "    read as full coverage of the harness. It never was."
else
  echo "=== SELF-TEST FAIL: $MISMATCHES mismatch(es). The harness is not measuring what it claims."
fi
exit "$MISMATCHES"
