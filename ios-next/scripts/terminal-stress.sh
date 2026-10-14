#!/usr/bin/env bash
# terminal-stress.sh: crash regression for terminals running a codex-like TUI.
#
#   ios-next/scripts/terminal-stress.sh [--slot S] [--rounds N]
#
# Builds and launches the app on the mock host with Mac-mirrored grids
# (CMUX_NEXT_MOCK_TERMINAL_MIRROR, so the term.mirror.v1 paths run) and the
# software keyboard, then for each grid size: opens the terminal card, runs
# `codexreplay` (the recorded codex v0.162 output stream: alternate screen,
# kitty keyboard, SGR mouse 1003/1006, synchronized output 2026, OSC 0/10/11,
# split at random chunk edges), and while it streams toggles the tab grid
# (live thumbnails read the surface), the keyboard, composer mode and the
# text size (the terminal list's DEBUG Cards screen hosts thumbnails and the
# embedded content). Fails if the app process dies or a new crash report appears.
# The fixture is ios-next/reference/fixtures/codex-104x40.bin
# (record_codex.py next to it re-records it on a Mac with codex).
set -euo pipefail
slot="stress"; rounds=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slot) slot="$2"; shift 2 ;;
    --rounds) rounds="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/remote-ios.sh"
HOST="${CMUX_NEXT_IOS_HOST:-aziz-other-macbook}"
alive() { ssh "$HOST" "pgrep -f 'CmuxNextDrawer.app/CmuxNextDrawer' >/dev/null"; }
crashes() { ssh "$HOST" "ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -c CmuxNextDrawer || true"; }
tap() { "$R" axe --slot "$slot" -- tap "$@" >/dev/null 2>&1 || echo "  (tap $* missed)"; }
check() {
  if ! alive; then echo "FAIL: app died ($1)" >&2; exit 1; fi
  local now; now=$(crashes)
  if [[ "$now" != "$before" ]]; then echo "FAIL: new crash report ($1)" >&2; exit 1; fi
}
before=$(crashes)
for grid in 104x40 220x60 50x20; do
  echo "== grid $grid"
  "$R" run --slot "$slot" --env CMUX_NEXT_DEV_SCREEN=terminal --env CMUX_NEXT_TERMINAL_CARDS=1 \
    --env CMUX_NEXT_MOCK_TERMINAL_MIRROR="$grid" --env CMUX_NEXT_SOFTWARE_KEYBOARD=1 | tail -1
  sleep 4
  tap -x 200 -y 210; sleep 2                      # first terminal row (zsh)
  tap -x 200 -y 300; sleep 1                      # focus: raw typing
  "$R" axe --slot "$slot" -- type "'codexreplay 60'" >/dev/null
  "$R" axe --slot "$slot" -- key 40 >/dev/null
  for i in $(seq 1 "$rounds"); do
    sleep 1; check "replay $i"
    tap --id terminal.key.composer; sleep 1; check "composer $i"
    tap --id terminal.key.composer; sleep 1
    tap -x 37 -y 84; sleep 1.5; check "back $i"     # list; the stream detaches
    tap --id terminal.cards; sleep 2.5; check "cards $i"   # live thumbnails attach
    tap -x 105 -y 200; sleep 2; check "card open $i"       # embedded content, external accessory
    tap -x 200 -y 300; sleep 1; check "card keyboard $i"
    tap --id cards.done; sleep 1
    tap --id cards.close; sleep 1.5                 # back to the list
    tap -x 200 -y 210; sleep 2; tap -x 200 -y 300; sleep 1
    "$R" axe --slot "$slot" -- type "'codexreplay 60'" >/dev/null
    "$R" axe --slot "$slot" -- key 40 >/dev/null
  done
  check "end of $grid"
  echo "ok $grid"
done
echo "PASS"
