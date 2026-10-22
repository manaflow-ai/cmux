#!/usr/bin/env bash
# perf-10x drag: pane and divider drags (LayoutDragBench: 120 Hz pointer
# replay, 3 s per gesture, through DividerHandleView -> LayoutModel ->
# advanceFrame -> layout/display) and the daemon cost of one drag value
# (perf-10x-drag-daemon.py against the published cmux-tui of this ref).
# Run alone on a worker:
#   cmux-ci run --class exclusive --measurement --script scripts/measure/perf-10x-drag.sh --ref SHA
#     [--arg=rounds=N] [--arg=config=release] [--arg=daemon=0] [--arg=swift=0] [--arg=panes=1]
# panes=1 also runs PaneMotionBench (split, Cmd-Shift-D, close, New Column, zoom at 2, 8 and 30 panes,
# stub content; PANE-BENCH lines); panes=only runs it alone.
set -euo pipefail
rounds=3
daemon=1
swift=1
panes=0
for arg in "$@"; do
  case "$arg" in
    rounds=*) rounds="${arg#rounds=}" ;;
    config=debug|config=release) export CMUX_SWIFT_SUITE_CONFIGURATION="${arg#config=}" ;;
    daemon=0|daemon=1) daemon="${arg#daemon=}" ;;
    swift=0|swift=1) swift="${arg#swift=}" ;;
    panes=0|panes=1) panes="${arg#panes=}" ;;
    panes=only) panes=1; daemon=0; swift=0 ;;
    *) echo "perf-10x-drag.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
echo "DRAG-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) sha=$(git rev-parse HEAD)"
echo "DRAG-CONFIG ${CMUX_SWIFT_SUITE_CONFIGURATION:-debug} rounds=$rounds"
status=0
if [ "$daemon" = 1 ]; then
  work="$root/.build/perf-drag"
  mkdir -p "$work"
  base="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}"
  key="$(python3 scripts/ci/cmux_tui_tree_key.py HEAD)"
  if curl -fsSL --proto '=https' "$base/tree/$key/cmux-tui-aarch64-apple-darwin" -o "$work/cmux-tui"; then
    sum="$(curl -fsSL --proto '=https' "$base/tree/$key/cmux-tui-aarch64-apple-darwin.sha256" | awk '{print $1}')"
    if [ "$(shasum -a 256 "$work/cmux-tui" | awk '{print $1}')" = "$sum" ]; then
      chmod +x "$work/cmux-tui"
      echo "DRAG-DAEMON-BIN key=$key"
      echo "DRAG-LOAD daemon-before $(uptime | sed 's/.*load averages*: //')"
      python3 scripts/measure/perf-10x-drag-daemon.py --bin "$work/cmux-tui" --n 360 || status=$?
    else
      echo "DRAG-DAEMON-BIN sha256 mismatch ($key)"; status=1
    fi
  else
    echo "DRAG-DAEMON-BIN no published cmux-tui tree for key $key"
  fi
fi
if [ "$swift" = 1 ]; then
  echo "DRAG-LOAD swift-before $(uptime | sed 's/.*load averages*: //')"
  CMUX_DRAG_BENCH=1 CMUX_DRAG_BENCH_ROUNDS="$rounds" \
    ./scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext LayoutDragBench || status=$?
  echo "DRAG-LOAD swift-after $(uptime | sed 's/.*load averages*: //')"
fi
if [ "$panes" = 1 ]; then
  CMUX_PANE_BENCH=1 ./scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext PaneMotionBench || status=$?
fi
exit "$status"
