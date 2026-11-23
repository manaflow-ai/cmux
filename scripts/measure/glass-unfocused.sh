#!/usr/bin/env bash
# The window backdrop focused and unfocused, pixel by pixel. Leo, 2026-10-25: "also when i go out of focus of the
# cmux-next app i still see it turn more frosted like it frosts the glass before the background". Builds the
# package tests and runs UnfocusedWindowPixelsTests alone (its ActiveLookScope must own the process's hook) in
# the console user's GUI session (scripts/ci/frame-pacing/console-session.sh): a real window with the window backdrop
# over a striped picture, captured by the window server while key, while another app window is key, and while the app
# is not active, under Regular Glass, Clear Glass and Frosted; plus the control (the glass with no scope, as before
# the fix), which must frost. GLASS_UNFOCUSED lines give each comparison's worst-channel error; the PNGs are the
# before/after shots.
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/glass-unfocused.sh --ref <sha> --artifact artifacts/glass-unfocused/glass-unfocused.tar.gz
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
out="$(pwd)/artifacts/glass-unfocused"
mkdir -p "$out/shots"
pkg=Packages/macOS/CmuxNext
echo "host $(hostname) $(sw_vers -productVersion)"
GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh /bin/bash -c '
  cd "$1"
  CMUX_TEST_REQUIRE_GUI=1 CMUX_GLASS_UNFOCUSED_OUT="$2/shots" \
    swift test --package-path "$3" --filter UnfocusedWindowPixelsTests 2>&1
' _ "$PWD" "$out" "$pkg" | tee "$out/run.log" || true
tar -czf "$out/glass-unfocused.tar.gz" -C "$out" run.log shots
grep '^GLASS_UNFOCUSED' "$out/run.log" || { echo "glass-unfocused: no results" >&2; exit 1; }
