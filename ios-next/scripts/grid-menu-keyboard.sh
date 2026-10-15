#!/usr/bin/env bash
# grid-menu-keyboard.sh: regression for the Tabs grid menus raising the
# software keyboard (tabs-parity-reaudit, blocker 1).
#
#   ios-next/scripts/grid-menu-keyboard.sh [--slot S] [--runs N]
#   AXE="<cmd that runs axe args>" SKIP_LAUNCH=1 ios-next/scripts/grid-menu-keyboard.sh
#
# Use a simulator with the hardware keyboard disconnected, or the software
# keyboard never shows. Each run launches the Tabs app on the mock host,
# opens the grid with the toolbar's Tabs button, opens (+) and then More,
# and requires every menu to still be open 1.2 s later with no keyboard
# keys in the accessibility tree. Before the fix the page surface stayed
# first responder over the grid, a menu brought up the keyboard, and the
# menu closed under it about 450 ms later. Exit 1 on the first failure.
set -euo pipefail
slot="kb"; runs=3
while [[ $# -gt 0 ]]; do case "$1" in --slot) slot="$2"; shift 2 ;; --runs) runs="$2"; shift 2 ;; *) echo "unknown arg $1" >&2; exit 2 ;; esac; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/remote-ios.sh"
axe() { if [[ -n "${AXE:-}" ]]; then $AXE "$@"; else "$R" axe --slot "$slot" -- "$@"; fi; }
ui() { axe describe-ui 2>/dev/null || true; }
keyboardUp() { grep -Eq '"AXLabel" *: *"(q|w|e|shift)"' <<<"$1"; }
check() {
  local name="$1" item="$2" out
  out=$(ui)
  if ! grep -q "\"AXLabel\" *: *\"$item\"" <<<"$out"; then echo "FAIL run $3: the $name menu closed" >&2; exit 1; fi
  if keyboardUp "$out"; then echo "FAIL run $3: the keyboard came up with the $name menu" >&2; exit 1; fi
  echo "ok run $3: $name menu open, keyboard down"
}
for i in $(seq 1 "$runs"); do
  if [[ -z "${SKIP_LAUNCH:-}" ]]; then
    "$R" launch --slot "$slot" --scheme Tabs --env CMUX_NEXT_DEV_SCREEN=tabs-combined >/dev/null
    sleep 6                                     # app launch and mock connect (test script only)
  fi
  axe tap -x 344 -y 816 >/dev/null; sleep 1.5     # Tabs button: the grid settles
  axe tap -x 62 -y 812 >/dev/null; sleep 1.2      # (+)
  check "(+)" "New Tab" "$i"
  axe tap -x 200 -y 300 >/dev/null; sleep 1.2     # dismiss (a tap outside the menu only closes it)
  axe tap -x 364 -y 84 >/dev/null; sleep 1.2      # More
  check "More" "Close All Tabs" "$i"
done
