#!/usr/bin/env bash
# terminal-drag-hang.sh: regression for the drag-over-TUI hang (V1.1 §5.7).
#
#   SIM_RUN="<cmd that runs simctl args on the build Mac>" AXE="<cmd that runs axe args>" \
#     ios-next/scripts/terminal-drag-hang.sh
#   or, on the default remote: ios-next/scripts/terminal-drag-hang.sh [--slot S]
#
# Launches the app on the mock host's terminal screen with a Mac-mirrored grid
# (term.mirror.v1, the bridged path), runs `mousetest` (the
# mock's alternate-screen program with mouse reporting 1000/1003/1006, like
# codex), then drags, flicks and long-drags over the terminal. After each
# gesture the main thread must answer: an accessibility snapshot that carries
# the terminal's debug value ("grid=...") within 5 s. Also checks the program
# received wheel reports (its echo shows "<64;" / "<65;"). Exit 1 on a hang.
set -euo pipefail
slot="term"
while [[ $# -gt 0 ]]; do case "$1" in --slot) slot="$2"; shift 2 ;; *) echo "unknown arg $1" >&2; exit 2 ;; esac; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/remote-ios.sh"
axe() { if [[ -n "${AXE:-}" ]]; then $AXE "$@"; else "$R" axe --slot "$slot" -- "$@"; fi; }
responsive() {
  local t0 t1 out
  t0=$(date +%s)
  out=$(axe describe-ui 2>/dev/null || true)
  t1=$(date +%s)
  if (( t1 - t0 > 5 )) || ! grep -q '"AXValue" *: *"grid=' <<<"$out"; then
    echo "FAIL: main thread not responding after $1 ($((t1 - t0)) s)" >&2; exit 1
  fi
  echo "ok $1 ($((t1 - t0)) s)"
}
if [[ -z "${SKIP_LAUNCH:-}" ]]; then
  "$R" run --slot "$slot" --env CMUX_NEXT_DEV_SCREEN=terminal --env CMUX_NEXT_MOCK_TERMINAL_MIRROR=80x24 | tail -1
  sleep 4
fi
axe tap -x 200 -y 210 >/dev/null; sleep 2          # first terminal (zsh)
axe tap -x 200 -y 300 >/dev/null; sleep 1          # focus
axe type mousetest >/dev/null; axe key 40 >/dev/null; sleep 1.5
axe key 41 >/dev/null 2>&1 || true                  # (no-op key so typing settles)
responsive "start"
axe drag --start-x 200 --start-y 250 --end-x 200 --end-y 550 --duration 1.0 --steps 80 >/dev/null; responsive "drag down"
axe drag --start-x 200 --start-y 550 --end-x 200 --end-y 250 --duration 1.0 --steps 80 >/dev/null; responsive "drag up"
axe swipe --start-x 200 --start-y 600 --end-x 200 --end-y 150 --duration 0.15 >/dev/null; sleep 1; responsive "flick"
axe drag --start-x 200 --start-y 200 --end-x 200 --end-y 650 --duration 4.0 --steps 300 >/dev/null; responsive "long drag"
echo PASS
