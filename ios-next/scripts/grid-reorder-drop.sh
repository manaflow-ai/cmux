#!/usr/bin/env bash
# grid-reorder-drop.sh: regression for a long-press reorder closing the
# dragged tab on the drop (tabs-parity-reaudit-2, D6b).
#
#   ios-next/scripts/grid-reorder-drop.sh [--slot S] [--runs N]
#   AXE="<cmd that runs axe args>" ios-next/scripts/grid-reorder-drop.sh
#
# Each run launches the Tabs app on the mock host (5 tabs), opens the grid,
# then long-presses the GitHub card and drags it left onto the first slot
# in steps that pause long enough for the long press (the re-audit's input:
# 197 pt over 6 s in 6 steps), and releases. The grid must still say
# "5 Tabs" and list the GitHub card. Exit 1 on the first failure.
set -euo pipefail
slot="kb"; runs=3
while [[ $# -gt 0 ]]; do case "$1" in --slot) slot="$2"; shift 2 ;; --runs) runs="$2"; shift 2 ;; *) echo "unknown arg $1" >&2; exit 2 ;; esac; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/remote-ios.sh"
axe() { if [[ -n "${AXE:-}" ]]; then $AXE "$@"; else "$R" axe --slot "$slot" -- "$@"; fi; }
for i in $(seq 1 "$runs"); do
  "$R" launch --slot "$slot" --scheme Tabs --env CMUX_NEXT_DEV_SCREEN=tabs-combined >/dev/null
  sleep 6                                         # app launch and mock connect (test script only)
  axe tap -x 344 -y 816 >/dev/null; sleep 1.5     # Tabs button: the grid settles
  axe drag --start-x 297 --start-y 250 --end-x 100 --end-y 250 --duration 6 --steps 6 >/dev/null
  sleep 1.5                                       # drop settles
  out=$(axe describe-ui 2>/dev/null || true)
  if ! grep -q '"AXLabel" *: *"5 Tabs"' <<<"$out"; then echo "FAIL run $i: the reorder closed a tab" >&2; exit 1; fi
  if ! grep -q 'debounce resize during rotation' <<<"$out"; then echo "FAIL run $i: the GitHub card is gone" >&2; exit 1; fi
  echo "ok run $i: 5 tabs after the long-press reorder"
done
