#!/usr/bin/env bash
# The journeys TUI load kit (scripts/journeys/tui-kit) on a fleet Mac: its own tests with the Mac's
# /usr/bin/python3 (3.9, curses, a real pty, vim), the compiled programs (rust/: built with cargo, their
# tests, and their output against the Python engine's), then the 120 fps gradient's pace per variant.
# No app, no GUI, no build:
#   cmux-ci run --class exclusive --script scripts/measure/tui-kit-selftest.sh --ref SHA --timeout 900 \
#     [--arg=pace_seconds=30]
# Output: TUI-KIT-HOST (host, macOS, python, vim, htop/btop present or not), the unittest lines (the kit's
# and load_profiles' against a stand-in app), one
# TUI-KIT-PACE-VARIANT line per variant (pace_probe.py: frame intervals p50/p95/p99/max, late frames,
# draw time, CPU), and TUI-KIT-PACE, the gradient's default (spin) again. Exit: the tests'.
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
# The compiled programs (cmux-ad 03:40Z): build, then their own tests (ignored in a plain cargo test).
# CMUX_TUIKIT_REQUIRE_RUST makes the parity and rate tests fail, never skip, when the build is missing.
cargo="$(command -v cargo || echo "$HOME/.cargo/bin/cargo")"
if "$py" "$kit/tuikit.py" build-bins; then
  "$cargo" test --release --offline --manifest-path "$kit/rust/Cargo.toml" -- --ignored || status=$?
else
  echo "TUI-KIT-BUILD failed" >&2
  status=1
fi
CMUX_TUIKIT_REQUIRE_RUST=1 "$py" "$kit/test_tuikit.py" || status=$?
"$py" "$kit/test_load_profiles.py" || status=$?
out="${TMPDIR:-/tmp}/tui-kit-selftest.$$"
mkdir -p "$out"
trap 'rm -rf "$out"' EXIT
"$py" "$kit/pace_probe.py" --seconds "$pace_seconds" --out "$out" | tee "$out/pace.txt"
# TUI-KIT-PACE: the default program (the compiled gradient when it built, else the Python spin).
if grep -q '^TUI-KIT-PACE-VARIANT rust-spin frames=' "$out/pace.txt"; then
  sed -n 's/^TUI-KIT-PACE-VARIANT rust-spin /TUI-KIT-PACE (default rust spin) /p' "$out/pace.txt"
else
  sed -n 's/^TUI-KIT-PACE-VARIANT spin /TUI-KIT-PACE (default spin) /p' "$out/pace.txt"
fi
exit "$status"
