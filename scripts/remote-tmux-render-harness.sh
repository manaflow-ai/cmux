#!/bin/bash
# ============================================================================
# Remote-tmux mirror RENDER-FIDELITY harness.
#
# Asserts the strong oracle that a weaker "is there a stray %?" check can't:
#
#     the mirror's rendered VISIBLE screen  ==  the remote pane's VISIBLE screen
#
# (after the attach/resize settles, at matched size). This catches the LAYOUT/CONTENT
# class of mirror render bugs at once: stacked/compacted prompts, the spurious zsh
# PROMPT_SP "%", history-in-the-visible-area, and any content drift — which is how a
# mis-seeded cursor usually surfaces too. It does NOT compare the cursor cell directly
# (read-screen returns text only); the cursor-placement logic is covered by the
# paneStateSeedSequence unit tests. It drives every edge that has regressed: fresh
# attach, prompt-redraw scrollback, mirror taller than the pane (H>P), mirror shorter
# (H<P), rapid re-attach, reconnect, and a mid-size pane.
#
# PREREQUISITES:
#   - A tagged Debug app built + running:  ./scripts/reload.sh --tag <tag> --launch
#     then run this with CMUX_TAG=<tag>.
#   - An ssh alias to localhost whose forced-command pins an isolated TMUX_TMPDIR,
#     so the harness never touches your real tmux. Defaults to `cmux-srvA` ->
#     /tmp/cmux-srvA. Example ~/.ssh/config:
#         Host cmux-srvA
#             HostName 127.0.0.1
#             RemoteCommand TMUX_TMPDIR=/tmp/cmux-srvA $SHELL -l
#             RequestTTY yes
#     Override with CMUX_RENDER_SRV / CMUX_RENDER_SRV_TMPDIR.
#
# Exit code is the number of failed scenarios (0 = all green).
# ============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${CMUX_TAG:?set CMUX_TAG to the tagged debug app (e.g. CMUX_TAG=lv-all)}"
TMUXBIN="${CMUX_RENDER_TMUX:-/opt/homebrew/bin/tmux}"
SRV="${CMUX_RENDER_SRV:-cmux-srvA}"
SRVDIR="${CMUX_RENDER_SRV_TMPDIR:-/tmp/cmux-srvA}"
UUID='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

# `timeout` is GNU coreutils; on macOS it's absent unless coreutils is installed
# (as `gtimeout`). Resolve one up front, fail fast with a clear prerequisite error.
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
[ -n "$TIMEOUT_BIN" ] || { echo "ERROR: neither 'timeout' nor 'gtimeout' found — install GNU coreutils (brew install coreutils)"; exit 2; }

# Poll a predicate until it succeeds or a deadline passes (no fixed sleeps to
# paper over readiness — the loop returns the instant the real signal is true).
wait_until() {  # $1=timeout_s  $2.. = predicate command
  local timeout_s="$1"; shift
  local deadline=$(( SECONDS + timeout_s ))
  until "$@"; do
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

srv() { TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" "$@"; }
cli() { CMUX_TAG="$CMUX_TAG" "$TIMEOUT_BIN" 25 "$REPO/scripts/cmux-debug-cli.sh" "$@" 2>&1; }
win_ids() { cli list-windows | awk '{for(i=1;i<=NF;i++) if($i ~ /^selected_workspace=/) print $(i-1)}'; }
# Normalize for comparison: right-trim each line, drop trailing blank lines.
norm() { sed 's/[[:space:]]*$//' | awk '{a[NR]=$0} END{last=NR; while(last>0 && a[last]=="") last--; for(i=1;i<=last;i++) print a[i]}'; }
# Capture helpers: `pipefail` propagates a failed capture-pane/read-screen so callers
# can tell "screen was empty" from "capture failed" instead of silently comparing "".
remote_visible() { srv capture-pane -p -t "$1" 2>/dev/null | norm; }
mirror_visible() { cli read-screen --window "$1" 2>/dev/null | norm; }
remote_pane_info() { srv display-message -p -t "$1" 'size=#{pane_width}x#{pane_height} cursor=#{cursor_x},#{cursor_y} hist=#{history_size}' 2>/dev/null; }

# ---- readiness predicates ----------------------------------------------------
srv_down() { ! srv list-sessions >/dev/null 2>&1; }
session_painted() { srv has-session -t "$1" 2>/dev/null && [ -n "$(remote_visible "$1")" ]; }
hist_at_least() { local h; h=$(srv display-message -p -t "$1" '#{history_size}' 2>/dev/null || echo 0); [ "${h:-0}" -ge "$2" ]; }
window_gone() { ! win_ids 2>/dev/null | grep -qF "$1"; }
new_window() { win_ids | sort -u | comm -13 <(printf '%s\n' "$1") - | grep -qiE "$UUID"; }
newest_window() { win_ids | sort -u | comm -13 <(printf '%s\n' "$1") - | grep -iE "$UUID" | head -1; }

reset_srv() { srv kill-server 2>/dev/null || true; wait_until 5 srv_down || true; mkdir -p "$SRVDIR"; }
new_session() {  # $1=session name, $2.. = extra new-session args; waits for prompt paint
  local s="$1"; shift; srv new-session -d -s "$s" "$@"; wait_until 10 session_painted "$s" || true;
}
gen_scrollback() {  # send n Enters, wait until history actually grows to n rows
  local s="$1" n="$2" i; for ((i=0;i<n;i++)); do srv send-keys -t "$s" Enter; done
  wait_until 10 hist_at_least "$s" "$n" || true
}
attach_window() {
  local before; before=$(win_ids | sort -u)
  cli ssh-tmux "$SRV" --no-focus >/dev/null 2>&1
  wait_until 25 new_window "$before" || true
  newest_window "$before"
}
# Kill ONLY the cmux-owned ssh ControlMaster for this server (used to force a
# reconnect). A broad `pkill -f "ssh.*$SRV"` treats the alias as a regex and can
# match unrelated user ssh; instead resolve specific PIDs whose command line
# carries the cmux ssh ControlPath (~/.cmux/ssh) AND this server's alias, and kill
# only those PIDs.
kill_srv_ssh() {
  local pids
  pids=$(pgrep -fl ssh 2>/dev/null | awk -v s="$SRV" '/\.cmux\/ssh\// && index($0, s) {print $1}')
  if [ -z "$pids" ]; then echo "  (reconnect: no cmux ssh for $SRV found)"; return 0; fi
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
}

R=""; M=""
# Compare the mirror's visible screen to the remote pane's, retrying until they
# match or a deadline passes (attach/reflow settles asynchronously). Requires a
# NON-EMPTY remote capture so a failed capture (both empty) can never false-PASS.
compare_settled() {  # $1=remote_session  $2=mirror_window ; sets R,M ; 0 on match
  local rs="$1" w="$2" deadline=$(( SECONDS + 20 ))
  while :; do
    R=$(remote_visible "$rs") || R=""
    M=$(mirror_visible "$w") || M=""
    { [ -n "$R" ] && [ "$R" = "$M" ]; } && return 0
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 0.5
  done
}

PASS=0; FAIL=0; FAILED=""
assert_match() {  # $1=label  $2=remote_session  $3=mirror_window
  local label="$1" rs="$2" w="$3"
  if [ -z "$w" ]; then FAIL=$((FAIL+1)); FAILED="$FAILED $label(no-window)"; echo "  FAIL  $label  (no mirror window)"; return; fi
  if compare_settled "$rs" "$w"; then
    PASS=$((PASS+1)); echo "  PASS  $label"
  else
    FAIL=$((FAIL+1)); FAILED="$FAILED $label"
    echo "  FAIL  $label  ($(remote_pane_info "$rs"))"
    echo "        remote=$(printf '%s' "$R" | grep -c .) non-blank lines  mirror=$(printf '%s' "$M" | grep -c .) non-blank lines"
    paste <(printf '%s\n' "$R" | cat -n) <(printf '%s\n' "$M" | cat -n) | head -8 | sed 's/^/        /'
  fi
  cli close-window --window "$w" >/dev/null 2>&1; wait_until 5 window_gone "$w" || true
}

echo "=== remote-tmux render-fidelity harness  tag=$CMUX_TAG  srv=$SRV ==="

reset_srv; new_session s1
assert_match "fresh-empty" s1 "$(attach_window)"

reset_srv; new_session s2; gen_scrollback s2 8
assert_match "scrollback-history" s2 "$(attach_window)"

reset_srv; new_session s3 -x 80 -y 12; gen_scrollback s3 6
assert_match "mirror-taller-HgtP" s3 "$(attach_window)"

reset_srv; new_session s4 -x 80 -y 60; gen_scrollback s4 4
assert_match "mirror-shorter-HltP" s4 "$(attach_window)"

reset_srv; new_session s6; gen_scrollback s6 5
before=$(win_ids | sort -u)
cli ssh-tmux "$SRV" --no-focus >/dev/null 2>&1; cli ssh-tmux "$SRV" --no-focus >/dev/null 2>&1
wait_until 25 new_window "$before" || true
assert_match "rapid-reattach" s6 "$(newest_window "$before")"

reset_srv; new_session s7; gen_scrollback s7 5
before=$(win_ids | sort -u); cli ssh-tmux "$SRV" --no-focus >/dev/null 2>&1
wait_until 25 new_window "$before" || true
W7=$(newest_window "$before")
kill_srv_ssh
if [ -n "$W7" ] && compare_settled s7 "$W7"; then
  PASS=$((PASS+1)); echo "  PASS  reconnect-reseed"
else
  FAIL=$((FAIL+1)); FAILED="$FAILED reconnect-reseed"; echo "  FAIL  reconnect-reseed"
fi
cli close-window --window "$W7" >/dev/null 2>&1; wait_until 5 window_gone "$W7" || true

reset_srv; new_session s8 -x 100 -y 20; gen_scrollback s8 6
assert_match "midsize-pane" s8 "$(attach_window)"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -gt 0 ] && echo "FAILED:$FAILED"
srv kill-server 2>/dev/null || true
exit "$FAIL"
