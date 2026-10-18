#!/usr/bin/env bash
# grid-menu-restore.sh: the long-pressed card is back after its menu closes
# (tabs-parity-reaudit-5, critical: it stopped drawing and lost its
# accessibility element after every menu path).
#
#   CMUX_NEXT_IOS_HOST=mini-cmux15 ios-next/scripts/grid-menu-restore.sh [--slot S] [--app tabs|kit] [PATH...]
#
# PATH is dismiss (a tap left of the menu), or a menu item: "Copy Link",
# "Duplicate Tab", "Pin Tab", "Select Tabs", "Close Other Tabs"; all of
# them by default. Each run launches the app (mock host, 5 tabs) or the kit
# demo, opens the grid, long-presses the right card in row 1 (GitHub; the
# kit's second card) until its menu is up, takes the path, and then
# requires the card's header colour in its slot (the app; the kit's card
# has no header colour) and the card in the accessibility tree. Exit 1 on the first failure.
set -uo pipefail
slot="tabs"; app="tabs"; paths=()
while [[ $# -gt 0 ]]; do case "$1" in --slot) slot="$2"; shift 2 ;; --app) app="$2"; shift 2 ;; *) paths+=("$1"); shift ;; esac; done
[[ ${#paths[@]} -eq 0 ]] && paths=(dismiss "Copy Link" "Duplicate Tab" "Pin Tab" "Select Tabs" "Close Other Tabs")
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/remote-ios.sh"
HOST="${CMUX_NEXT_IOS_HOST:-aziz-other-macbook}"
U=$(ssh "$HOST" "cat ~/nx-ios/$slot/sim.udid")
axe() { ssh "$HOST" "axe $* --udid $U 2>/dev/null || ~/nx-ios/axe/axe $* --udid $U 2>/dev/null"; }
OUT="${TMPDIR:-/tmp}/grid-menu-restore/$slot"; mkdir -p "$OUT"
if [[ $app == kit ]]; then label="Liquid Glass"; color="-"; else label="terminal: debounce"; color="1f853c"; fi
fail=0
for p in "${paths[@]}"; do
  if [[ $app == kit ]]; then
    ssh "$HOST" "xcrun simctl terminate $U dev.cmux.tabskit.demo >/dev/null 2>&1; xcrun simctl launch $U dev.cmux.tabskit.demo >/dev/null"
    sleep 4                                       # launch (test script only)
  else
    "$R" launch --slot "$slot" --scheme Tabs --env CMUX_NEXT_DEV_SCREEN=tabs-combined --env CMUX_NEXT_TABS_RESET_PINS=1 >/dev/null
    sleep 6                                       # launch and mock connect (test script only)
  fi
  axe tap -x 344 -y 816 >/dev/null; sleep 1.5     # Tabs: the grid settles
  axe touch -x 297 -y 250 --down --up --delay 1.5 >/dev/null; sleep 0.8   # long press: the menu is up
  if [[ $p == dismiss ]]; then axe tap -x 40 -y 600 >/dev/null; else axe tap --label "\"$p\"" >/dev/null; fi
  sleep 1.5                                       # the menu and its action settle
  [[ $p == "Select Tabs" ]] && { axe tap --label Done >/dev/null; sleep 1; }   # out of Select mode
  ui=$(axe describe-ui || true)
  shot="$OUT/$(tr ' ' _ <<<"$p").png"
  ssh "$HOST" "xcrun simctl io $U screenshot /tmp/gmr-$slot.png >/dev/null 2>&1"; scp -q "$HOST:/tmp/gmr-$slot.png" "$shot" || true
  c="$color"; [[ $p == "Pin Tab" ]] && c="-"     # pinned: a capsule in the pinned row
  res=$(python3 "$HERE/grid-menu-restore-check.py" "$shot" "$c" "$label" "$app" <<<"$ui")
  if [[ $res == ok ]]; then echo "ok $p: the card is back"; else echo "FAIL $p: $res"; fail=1; fi
done
exit $fail
