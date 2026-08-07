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
# Usage: CMUX_TAG=<tag> bash scripts/scrollback-resize-guard.sh [cycles] [lines]

set -uo pipefail
TAG="${CMUX_TAG:?set CMUX_TAG}"
CYCLES="${1:-8}"
NLINES="${2:-400}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOCKDIR=/tmp/cm-dragguard-$TAG
LOG=/tmp/dragtmux-$TAG.log
cli() { CMUX_QUIET=1 CMUX_TAG="$TAG" "$REPO/scripts/cmux-debug-cli.sh" "$@"; }

echo "== tmux drag guard tag=$TAG cycles=$CYCLES lines=$NLINES"
: > "$LOG"
mkdir -p "$SOCKDIR"

WIN=$(cli current-window | grep -oE '[0-9A-Fa-f-]{36}' | head -1)
[ -n "$WIN" ] || { echo "FAIL: no window"; exit 2; }
SIZE=$(cli resize-window --window "$WIN" --height 900)
H=$(echo "$SIZE" | awk '{print $3}')
[ -n "$H" ] || { echo "FAIL: could not read window size: $SIZE"; exit 2; }
SHORT=$((H - 300))
echo "window=$WIN height=$H short=$SHORT"

WS=$(cli new-workspace --name "dragtmux-$TAG" --cwd /tmp | awk '{print $2}')
PANE=$(cli list-panes --workspace "$WS" | grep -oE 'pane:[0-9]+' | sed -n 1p)
SURF=$(cli list-pane-surfaces --workspace "$WS" --pane "$PANE" | grep -oE 'surface:[0-9]+' | head -1)
echo "workspace=$WS pane=$PANE surface=$SURF"
cli select-workspace --workspace "$WS" >/dev/null
cli focus-pane --pane "$PANE" --workspace "$WS" >/dev/null
sleep 2

run() { cli send --surface "$SURF" "$1" >/dev/null; cli send-key --surface "$SURF" enter >/dev/null; }
snap() { cli read-screen --surface "$SURF" --scrollback --lines 8000 | grep -oE '^L[0-9]{4}$'; }

cleanup() {
  TMUX_TMPDIR="$SOCKDIR" tmux -L dg kill-server >/dev/null 2>&1
  cli close-workspace --workspace "$WS" >/dev/null 2>&1
  cli resize-window --window "$WIN" --height "$H" >/dev/null 2>&1
}
trap cleanup EXIT

# Prove the window resize reaches the terminal. This runs before tmux starts, so
# the row count comes back on the shell's own stdout.
probe_rows() { run "tput lines"; sleep 1.5; cli read-screen --surface "$SURF" --lines 60 | grep -oE '^[0-9]+$' | tail -1; }
cli resize-window --window "$WIN" --height "$SHORT" >/dev/null; sleep 1.5; R1=$(probe_rows)
cli resize-window --window "$WIN" --height "$H" >/dev/null;     sleep 1.5; R2=$(probe_rows)
echo "rows across one drag: $R1 -> $R2"
if [ -z "$R1" ] || [ "$R1" = "$R2" ]; then
  echo "FAIL: window resize did not change the terminal row count"; exit 2
fi

# tmux, in its own server, is the thing that repaints after each resize. It has
# to run the way t-claude configures it: smcup@/rmcup@ keeps it off the alternate
# screen and indn@ makes it scroll with plain newlines, so its output lands in
# ghostty's own scrollback. On the alternate screen there is no history to push
# rows into and the resize path under test is never reached.
run "clear; TMUX_TMPDIR=$SOCKDIR tmux -L dg new-session -A -s dg"
sleep 4
TMUX_TMPDIR="$SOCKDIR" tmux -L dg set-option -ga terminal-overrides ',*:smcup@:rmcup@' 2>/dev/null
TMUX_TMPDIR="$SOCKDIR" tmux -L dg set-option -ga terminal-overrides ',*:indn@' 2>/dev/null
TMUX_TMPDIR="$SOCKDIR" tmux -L dg set-option -t dg history-limit 10000 2>/dev/null
TMUX_TMPDIR="$SOCKDIR" tmux -L dg set-option -t dg status off 2>/dev/null
# terminal-overrides is read when a client attaches, so the running client has to
# come back through it.
run "tmux detach-client"
sleep 2
run "TMUX_TMPDIR=$SOCKDIR tmux -L dg attach -t dg"
sleep 3
if ! TMUX_TMPDIR="$SOCKDIR" tmux -L dg has-session -t dg 2>/dev/null; then
  echo "FAIL: tmux session did not start"; exit 2
fi

run "for i in \$(seq 1 $NLINES); do printf 'L%04d\\n' \$i; done"
sleep 4
# Park the cursor above the bottom row, the way a TUI sitting in its input box
# does. The sleep is reaped with the tmux server, never interrupted: a ctrl+c
# would redraw a prompt over the rows under test.
run "printf '\\033[12;1H'; sleep 900"
sleep 2

snap > /tmp/dragtmux-$TAG-before.txt
BEFORE=$(grep -c . /tmp/dragtmux-$TAG-before.txt)
# tmux keeps its own history, so ghostty holds one screenful. A near-full screen
# is the precondition the shrink needs: with blank rows to trim it never pushes
# real content into history. Anything above this count later came from a resize.
echo "parked: $BEFORE numbered lines in ghostty scrollback (screen is $R2 rows)"
[ "$BEFORE" -ge $((R2 - 6)) ] || { echo "FAIL: screen not full ($BEFORE of $R2 rows)"; exit 2; }

for c in $(seq 1 "$CYCLES"); do
  cli resize-window --window "$WIN" --height "$SHORT" >> "$LOG" 2>&1
  sleep 1.5
  cli resize-window --window "$WIN" --height "$H" >> "$LOG" 2>&1
  sleep 1.5
  echo "cycle $c lines=$(snap | grep -c .)" >> "$LOG"
done
sleep 2

snap > /tmp/dragtmux-$TAG-after.txt
AFTER=$(grep -c . /tmp/dragtmux-$TAG-after.txt)
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
