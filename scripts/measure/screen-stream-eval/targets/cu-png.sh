#!/usr/bin/env bash
# Screen stream eval target: the computer-use preview's frame path as the app runs it today
# (CmuxNextComputerUse ComputerUseLiveCapture: a window stream read at 6 fps, scaled to 360 px, PNG,
# base64 data URL), replayed by ../cu-png.swift on the scene's window. It is host and viewer at once,
# so it has no host to start and no latency (a still image per read has no input path). Compare it
# with rd-window, the same window as a cmux.rd/1 stream at the same 360 px rung (hq#9837 fix 2).
set -euo pipefail
verb=$1
shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$verb" in
  build)
    swiftc -O -o "$EVAL_BIN/screen-eval-cu-png" "$here/cu-png.swift"
    swiftc -O -o "$EVAL_BIN/screen-eval-window-id" "$here/window-id.swift"
    ;;
  host-start)
    # Only the window rows need the scene's window; the latency stage has none to stream.
    "$EVAL_BIN/screen-eval-window-id" screen-eval-scene >"$EVAL_STATE/window" ||
      { echo "cu-png: no scene window (this target measures the window rows only)" >&2; exit 1; }
    ;;
  host-stop) rm -f "$EVAL_STATE/window" ;;
  latency-view | latency-report) exit 0 ;;
  window-view)
    seconds=$1 snapshot=$2 go=$3 raw=$4
    "$EVAL_BIN/screen-eval-cu-png" "$(cat "$EVAL_STATE/window")" "$seconds" "$snapshot" "$go" "$raw" \
      "${EVAL_CU_PNG_FPS:-6}" "${EVAL_CU_PNG_LONG_SIDE:-360}" 2>"$EVAL_STATE/window.err"
    ;;
  window-report)
    raw=$1 out=$2
    python3 -I - "$raw" "$out" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
json.dump({"series": raw["series"], "extra": raw.get("extra") or {}}, open(sys.argv[2], "w"))
PY
    ;;
  *) echo "cu-png.sh: unknown verb $verb" >&2; exit 2 ;;
esac
