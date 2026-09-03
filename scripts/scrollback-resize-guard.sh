#!/bin/bash
# Drags a window's bottom edge and checks that the terminal's scrollback does
# not grow. Repeated height changes used to leak rows: a shrink pushes the top
# of the screen into history, and the matching grow appends blank rows instead
# of pulling those rows back, so scrolling up showed the same lines again.
#
# Two things have to be true for the leak to happen, and both took a while to
# get right. The screen must be full, so the shrink has no blank rows to trim
# and has to push real content. And something above the terminal must repaint
# at the new size, or the leak is only trailing blanks, which read-screen
# strips and no check can see. tmux supplies the repaint, but only with the
# alternate screen turned off -- on the alternate screen there is no history to
# push into and the resize path is never reached.
#
# The verdict is scrollback growth. Duplicate lines are reported but not
# graded: tmux's repaint writes a second copy of the visible rows whether or
# not the terminal is fixed, so duplicates appear either way. Measured over 8
# cycles: 400 lines becomes 437 on a terminal without the fix and 402 with it.
#
# The window is driven through cmux's own resize-window verb. AppleScript
# cannot do it: from an automation host every app, cmux included, reports zero
# windows through System Events for lack of Accessibility permission.
#
# Sequencing waits on observable edges, not fixed delays. The debug CLI is a
# snapshot interface -- the only way to see the terminal is to read it -- so
# each edge is a marker or state the screen must reach, re-read until it
# appears, bounded by a deadline that fails the run instead of passing it.
#
# Usage: CMUX_TAG=<tag> bash scripts/scrollback-resize-guard.sh [cycles] [lines]

set -uo pipefail
TAG="${CMUX_TAG:?set CMUX_TAG}"
CYCLES="${1:-8}"
NLINES="${2:-400}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOCKDIR=/tmp/cm-dragguard-$TAG
LOG=/tmp/dragtmux-$TAG.log
cli() { CMUX_QUIET=1 CMUX_TAG="$TAG" "$REPO/scripts/cmux-debug-cli.sh" "$@"; }

fail() { echo "FAIL: $1"; exit 2; }

# Re-reads an observable until the given command succeeds, bounded by a
# deadline. $1=seconds, $2=description, rest = the predicate command.
wait_until() {
  local deadline=$((SECONDS + $1)) desc="$2"; shift 2
  while ! "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || fail "timed out waiting for $desc"
    sleep 0.2
  done
}

echo "== tmux drag guard tag=$TAG cycles=$CYCLES lines=$NLINES"
: > "$LOG"
mkdir -p "$SOCKDIR"

WIN=$(cli current-window | grep -oE '[0-9A-Fa-f-]{36}' | head -1)
[ -n "$WIN" ] || fail "no window"

# The authoritative frame before anything moves, so cleanup restores the
# window the user actually had rather than the post-resize height.
ORIG=$(cli resize-window --window "$WIN") || fail "could not read window frame: $ORIG"
ORIG_H=$(echo "$ORIG" | awk '$1 == "OK" {print $3}')
[ -n "$ORIG_H" ] || fail "could not parse window frame: $ORIG"

WS=""
cleanup() {
  TMUX_TMPDIR="$SOCKDIR" tmux -L dg kill-server >/dev/null 2>&1
  [ -n "$WS" ] && cli close-workspace --workspace "$WS" >/dev/null 2>&1
  cli resize-window --window "$WIN" --height "$ORIG_H" >/dev/null 2>&1
}
trap cleanup EXIT

SIZE=$(cli resize-window --window "$WIN" --height 900) || fail "resize to 900 failed: $SIZE"
H=$(echo "$SIZE" | awk '$1 == "OK" {print $3}')
[ -n "$H" ] || fail "could not read window size: $SIZE"
SHORT=$((H - 300))
echo "window=$WIN orig_height=$ORIG_H height=$H short=$SHORT"

WS=$(cli new-workspace --name "dragtmux-$TAG" --cwd /tmp | awk '{print $2}')
PANE=$(cli list-panes --workspace "$WS" | grep -oE 'pane:[0-9]+' | sed -n 1p)
SURF=$(cli list-pane-surfaces --workspace "$WS" --pane "$PANE" | grep -oE 'surface:[0-9]+' | head -1)
echo "workspace=$WS pane=$PANE surface=$SURF"
cli select-workspace --workspace "$WS" >/dev/null || fail "select-workspace failed"
cli focus-pane --pane "$PANE" --workspace "$WS" >/dev/null || fail "focus-pane failed"

run() { cli send --surface "$SURF" "$1" >/dev/null; cli send-key --surface "$SURF" enter >/dev/null; }
screen_has() { cli read-screen --surface "$SURF" --lines 200 | grep -q "$1"; }
snap() { cli read-screen --surface "$SURF" --scrollback --lines 8000 | grep -oE '^L[0-9]{4}$'; }

# The shell is ready when it can echo a marker back.
run "echo SHELL-READY-$$"
wait_until 15 "the new workspace's shell" screen_has "SHELL-READY-$$"

# Prove the window resize reaches the terminal. This runs before tmux starts,
# so the row count comes back on the shell's own stdout. Each probe carries its
# own marker; the edge is that marker appearing with a row count after it.
PROBE=0
probe_rows() {
  PROBE=$((PROBE + 1))
  run "printf 'ROWS-$$-$PROBE:%s\\n' \$(tput lines)"
  wait_until 15 "row probe $PROBE" screen_has "ROWS-$$-$PROBE:"
  cli read-screen --surface "$SURF" --lines 200 \
    | grep -oE "ROWS-$$-$PROBE:[0-9]+" | tail -1 | cut -d: -f2
}
cli resize-window --window "$WIN" --height "$SHORT" >/dev/null || fail "shrink failed"
R1=$(probe_rows)
cli resize-window --window "$WIN" --height "$H" >/dev/null || fail "grow failed"
R2=$(probe_rows)
echo "rows across one drag: $R1 -> $R2"
if [ -z "$R1" ] || [ "$R1" = "$R2" ]; then
  fail "window resize did not change the terminal row count"
fi

# tmux, in its own server, is the thing that repaints after each resize. It has
# to run the way t-claude configures it: smcup@/rmcup@ keeps it off the alternate
# screen and indn@ makes it scroll with plain newlines, so its output lands in
# ghostty's own scrollback. On the alternate screen there is no history to push
# rows into and the resize path under test is never reached.
run "clear; TMUX_TMPDIR=$SOCKDIR tmux -L dg new-session -A -s dg"
wait_until 20 "the tmux session" \
  env TMUX_TMPDIR="$SOCKDIR" tmux -L dg has-session -t dg
TMUX_TMPDIR="$SOCKDIR" tmux -L dg set-option -ga terminal-overrides ',*:smcup@:rmcup@' \
  || fail "could not disable the tmux alternate screen"
TMUX_TMPDIR="$SOCKDIR" tmux -L dg set-option -ga terminal-overrides ',*:indn@' \
  || fail "could not set the indn override"
TMUX_TMPDIR="$SOCKDIR" tmux -L dg set-option -t dg history-limit 10000 \
  || fail "could not raise the tmux history limit"
TMUX_TMPDIR="$SOCKDIR" tmux -L dg set-option -t dg status off \
  || fail "could not turn the tmux status line off"
# terminal-overrides is read when a client attaches, so the running client has
# to come back through it. The reattached client is ready when it can render a
# marker typed into the tmux pane.
run "tmux detach-client"
run "TMUX_TMPDIR=$SOCKDIR tmux -L dg attach -t dg"
run "echo TMUX-READY-$$"
wait_until 20 "the reattached tmux client" screen_has "TMUX-READY-$$"

run "clear; for i in \$(seq 1 $NLINES); do printf 'L%04d\\n' \$i; done"
LAST=$(printf 'L%04d' "$NLINES")
wait_until 30 "the $NLINES numbered lines" screen_has "^$LAST\$"
# Park the cursor above the bottom row, the way a TUI sitting in its input box
# does. The sleep is reaped with the tmux server, never interrupted: a ctrl+c
# would redraw a prompt over the rows under test. The PARKED marker prints
# first, so its appearance means the park command is running.
run "printf 'PARKED\\n'; printf '\\033[12;1H'; sleep 900"
wait_until 15 "the parked cursor" screen_has "PARKED"

snap > /tmp/dragtmux-$TAG-before.txt || fail "read-screen failed on the before snapshot"
BEFORE=$(grep -c . /tmp/dragtmux-$TAG-before.txt)
# tmux keeps its own history, so ghostty holds one screenful. A near-full screen
# is the precondition the shrink needs: with blank rows to trim it never pushes
# real content into history. Anything above this count later came from a resize.
echo "parked: $BEFORE numbered lines in ghostty scrollback (screen is $R2 rows)"
[ "$BEFORE" -ge $((R2 - 6)) ] || fail "screen not full ($BEFORE of $R2 rows)"

# The pane is running `sleep 900`, so nothing can echo a marker mid-cycle. The
# observable edge of each resize is the repaint itself: the number of L-lines
# visible on screen tracks the terminal's row count, so it falls after a
# shrink and rises after a grow.
visible_lines() { cli read-screen --surface "$SURF" --lines 200 | grep -cE '^L[0-9]{4}$'; }
vis_below() { [ "$(visible_lines)" -lt "$1" ]; }
vis_at_least() { [ "$(visible_lines)" -ge "$1" ]; }
TALL_VIS=$(visible_lines)
for c in $(seq 1 "$CYCLES"); do
  cli resize-window --window "$WIN" --height "$SHORT" >> "$LOG" 2>&1 \
    || fail "shrink resize failed during cycle $c"
  wait_until 15 "the shrink repaint in cycle $c" vis_below "$TALL_VIS"
  cli resize-window --window "$WIN" --height "$H" >> "$LOG" 2>&1 \
    || fail "grow resize failed during cycle $c"
  wait_until 15 "the grow repaint in cycle $c" vis_at_least "$TALL_VIS"
  echo "cycle $c lines=$(snap | grep -c .)" >> "$LOG"
done

snap > /tmp/dragtmux-$TAG-after.txt || fail "read-screen failed on the after snapshot"
AFTER=$(grep -c . /tmp/dragtmux-$TAG-after.txt)
# An empty or shrunken snapshot is a broken read, not a passing terminal: the
# parked rows cannot leave the buffer, so AFTER below BEFORE means the snapshot
# lied and the growth comparison would pass vacuously.
[ "$AFTER" -ge "$BEFORE" ] || fail "after snapshot returned $AFTER lines (before had $BEFORE) -- snapshot failed"
UNI=$(sort -u /tmp/dragtmux-$TAG-after.txt | grep -c .)
echo "after $CYCLES drag cycles: $AFTER numbered lines, $UNI unique"

FAIL=0
# The verdict is buffer growth, which is what the leak is: rows pushed into
# history that the matching grow never pulls back. Duplicates alone do not
# discriminate -- tmux repaints the screen after every resize and that repaint
# writes a second copy of the visible rows on a fixed build too, so both arms
# show some. Growth separates them: 8 cycles cost ~37 lines unfixed and ~2 fixed.
DUPCOUNT=$(sort /tmp/dragtmux-$TAG-after.txt | uniq -d | grep -c .)
echo "duplicated lines: $DUPCOUNT (informational; tmux repaint duplicates on any build)"
if [ "$AFTER" -gt "$((BEFORE + 5))" ]; then
  echo "FAIL: scrollback grew by $((AFTER - BEFORE)) lines across $CYCLES drag cycles"; FAIL=1
fi

[ "$FAIL" = 0 ] && echo "DRAG_RESULT=PASS" || echo "DRAG_RESULT=FAIL"
exit "$FAIL"
