#!/usr/bin/env bash
# grid-reorder.sh: long-press reorder on the Tabs grid, left, right and down
# (tabs-parity-reaudit-4 D6b).
#
#   CMUX_NEXT_IOS_HOST=mini-cmux15 ios-next/scripts/grid-reorder.sh [--slot S] [--runs N] [DIR...]
#
# DIR is left (GitHub onto cmux's slot), right (cmux onto GitHub's), down
# (GitHub onto zsh's) or up (Hacker News onto cmux's); all four by default. Each run launches the Tabs app
# on the mock host (5 tabs), opens the grid, long-presses the card and drags
# it in steps that pause long enough for the long press (the re-audit's
# input: about 200 pt over 6 s in 6 steps), and releases. Halfway through
# the drag a screenshot must show the dragged card itself under the finger
# (its header colour; the re-audit saw a blank white rectangle). After the
# drop the grid must still say "5 Tabs" and list the cards in the new order.
# Exit 1 on the first failure.
set -uo pipefail
slot="tabs"; runs=3; dirs=()
while [[ $# -gt 0 ]]; do case "$1" in --slot) slot="$2"; shift 2 ;; --runs) runs="$2"; shift 2 ;; *) dirs+=("$1"); shift ;; esac; done
[[ ${#dirs[@]} -eq 0 ]] && dirs=(left right down up)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/remote-ios.sh"
HOST="${CMUX_NEXT_IOS_HOST:-aziz-other-macbook}"
U=$(ssh "$HOST" "cat ~/nx-ios/$slot/sim.udid")
axe() { ssh "$HOST" "axe $* --udid $U 2>/dev/null || ~/nx-ios/axe/axe $* --udid $U 2>/dev/null"; }
OUT="${TMPDIR:-/tmp}/grid-reorder/$slot"; mkdir -p "$OUT"
fail=0
for d in "${dirs[@]}"; do
  # start, end (points), the dragged card's header colour, the expected order
  case "$d" in
    left)  s="297 250"; e="100 250"; c="1f853c"; want="terminal: debounce|cmux|Hacker News|zsh|top" ;;
    right) s="104 250"; e="300 250"; c="5b59e4"; want="terminal: debounce|cmux|Hacker News|zsh|top" ;;
    down)  s="297 250"; e="297 540"; c="1f853c"; want="cmux|Hacker News|zsh|terminal: debounce|top" ;;
    up)    s="104 540"; e="104 250"; c="fa6500"; want="Hacker News|cmux|terminal: debounce|zsh|top" ;;
    *) echo "unknown direction $d" >&2; exit 2 ;;
  esac
  read -r sx sy <<<"$s"; read -r ex ey <<<"$e"
  for i in $(seq 1 "$runs"); do
    "$R" launch --slot "$slot" --scheme Tabs --env CMUX_NEXT_DEV_SCREEN=tabs-combined --env CMUX_NEXT_TABS_RESET_PINS=1 >/dev/null
    sleep 6                                         # app launch and mock connect (test script only)
    axe tap -x 344 -y 816 >/dev/null; sleep 1.5     # Tabs button: the grid settles
    # The drag runs 6 s; the screenshot is taken 4.5 s in (after the third step).
    ssh "$HOST" "rm -f /tmp/gr-$slot.png; (sleep 4.5; xcrun simctl io $U screenshot /tmp/gr-$slot.png >/dev/null 2>&1) & (axe drag --start-x $sx --start-y $sy --end-x $ex --end-y $ey --duration 6 --steps 6 --udid $U || ~/nx-ios/axe/axe drag --start-x $sx --start-y $sy --end-x $ex --end-y $ey --duration 6 --steps 6 --udid $U) >/dev/null 2>&1; wait"
    sleep 1.5                                       # drop settles
    scp -q "$HOST:/tmp/gr-$slot.png" "$OUT/$d-$i.png" || true
    # The finger 4.5 s into 6 steps over 6 s: after 4 of the 6 moves.
    fx=$(( sx + (ex - sx) * 4 / 6 )); fy=$(( sy + (ey - sy) * 4 / 6 ))
    ui=$(axe describe-ui || true)
    res=$(python3 "$HERE/grid-reorder-check.py" "$OUT/$d-$i.png" "$c" "$fx" "$fy" "$want" <<<"$ui")
    if [[ $res == ok ]]; then echo "ok $d run $i: the card followed the finger and moved"; else echo "FAIL $d run $i: $res"; fail=1; fi
  done
done
exit $fail
