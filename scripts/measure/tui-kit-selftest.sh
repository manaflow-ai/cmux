#!/usr/bin/env bash
# The journeys TUI load kit (scripts/journeys/tui-kit) on a fleet Mac: its own tests with the Mac's
# /usr/bin/python3 (3.9, curses, a real pty, vim), then the 120 fps gradient's pace per pacing variant.
# No app, no GUI, no build:
#   cmux-ci run --class exclusive --script scripts/measure/tui-kit-selftest.sh --ref SHA --timeout 900 \
#     [--arg=pace_seconds=30]
# Output: TUI-KIT-HOST (host, macOS, python, vim, htop/btop present or not), the unittest lines, one
# TUI-KIT-PACE-VARIANT line per variant (pace_probe.py: frame intervals p50/p95/p99/max, late frames,
# draw time, CPU), and TUI-KIT-PACE, the default (sleep) again. Exit: the tests'.
set -euo pipefail
pace_seconds=30
for arg in "$@"; do
  case "$arg" in
    pace_seconds=*) pace_seconds="${arg#pace_seconds=}" ;;
    *) echo "tui-kit-selftest.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$pace_seconds" =~ ^[0-9]+$ ]] || { echo "tui-kit-selftest.sh: pace_seconds= is a whole number" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
kit="$root/scripts/journeys/tui-kit"
py=/usr/bin/python3
have() { command -v "$1" >/dev/null 2>&1 && echo yes || echo no; }
echo "TUI-KIT-HOST host=$(scutil --get ComputerName 2>/dev/null || hostname) macos=$(sw_vers -productVersion 2>/dev/null)" \
  "python=$($py -c 'import platform; print(platform.python_version())')" \
  "vim=$(vim --version 2>/dev/null | head -1 | tr ' ' '_')" "htop=$(have htop) btop=$(have btop)" \
  "rev=$(git -C "$root" rev-parse HEAD)"
status=0
"$py" "$kit/test_tuikit.py" || status=$?
out="${TMPDIR:-/tmp}/tui-kit-selftest.$$"
mkdir -p "$out"
trap 'rm -rf "$out"' EXIT
"$py" "$kit/pace_probe.py" --seconds "$pace_seconds" --out "$out" | tee "$out/pace.txt"
sed -n 's/^TUI-KIT-PACE-VARIANT sleep /TUI-KIT-PACE (default sleep) /p' "$out/pace.txt"
exit "$status"
