#!/usr/bin/env bash
# The journeys TUI load kit (scripts/journeys/tui-kit) on a fleet Mac: its own tests with the Mac's
# /usr/bin/python3 (3.9, curses, a real pty, vim), then the 120 fps gradient's pace on that Mac.
# No app, no GUI, no build:
#   cmux-ci run --class exclusive --script scripts/measure/tui-kit-selftest.sh --ref SHA --timeout 900
# Output: TUI-KIT-HOST (host, macOS, python, vim, htop/btop present or not), the unittest lines,
# TUI-KIT-PACE (frames in 5 s at 120 fps and the late frames, from the frame log). Exit: the tests'.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
kit="$root/scripts/journeys/tui-kit"
py=/usr/bin/python3
have() { command -v "$1" >/dev/null 2>&1 && echo yes || echo no; }
echo "TUI-KIT-HOST host=$(scutil --get ComputerName 2>/dev/null || hostname) macos=$(sw_vers -productVersion)" \
  "python=$($py -c 'import platform; print(platform.python_version())')" \
  "vim=$(vim --version 2>/dev/null | head -1 | tr ' ' '_')" "htop=$(have htop) btop=$(have btop)" \
  "rev=$(git -C "$root" rev-parse HEAD)"
status=0
"$py" "$kit/test_tuikit.py" || status=$?
out="${TMPDIR:-/tmp}/tui-kit-selftest.$$"
mkdir -p "$out"
trap 'rm -rf "$out"' EXIT
"$py" "$kit/tuikit.py" gradient --seed 1 --size 160x48 --duration 5 --log "$out/frames.jsonl" >/dev/null
"$py" - "$out/frames.jsonl" <<'EOF'
import json, sys
frames = [e for e in map(json.loads, open(sys.argv[1])) if e["ev"] == "frame"]
late = sorted(e["late_ms"] for e in frames)
over = sum(1 for v in late if v > 1000 / 120)
print("TUI-KIT-PACE frames=%d in 5 s (target 600) late_over_one_frame=%d max_late_ms=%.2f" % (len(frames), over, late[-1] if late else 0))
EOF
exit "$status"
