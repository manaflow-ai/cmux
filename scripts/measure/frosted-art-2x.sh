#!/usr/bin/env bash
# Frosted over a picture at 2x (cmux#51381): Leo, 2026-11-23, on a Studio Display XDR: "it went only to the bottom
# left". Starts a backing-scale-2 virtual display (scripts/ci/frame-pacing/vdisplay.m, hidpi) in the console user's GUI
# session and runs scripts/measure/frosted-art-2x.swift there: a window whose art view is configured as
# WindowMaterialView's, showing a 4 px checkerboard, blurred three ways (none, live layer filters as applyArtBlur did,
# and a pre-blurred still as the fix does), captured before and after a stepped resize. Each RESULT line gives, per
# quadrant, how much of it is blurred, sharp, or not covered at all (the red window behind the art).
#   cmux-ci run --class exclusive --measurement --label measure --target-worker aws-m4pro-7 --pin-strict \
#     --script scripts/measure/frosted-art-2x.sh --ref <sha> --artifact artifacts/frosted-art-2x/frosted-art-2x.tar.gz
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
out="$(pwd)/artifacts/frosted-art-2x"
mkdir -p "$out/VDisplay.app/Contents/MacOS"
xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework AppKit -framework CoreVideo \
  scripts/ci/frame-pacing/vdisplay.m -o "$out/VDisplay.app/Contents/MacOS/VDisplay"
cp scripts/ci/frame-pacing/VDisplay-Info.plist "$out/VDisplay.app/Contents/Info.plist"
codesign -s - --force "$out/VDisplay.app" 2>/dev/null || true
xcrun swiftc -O scripts/measure/frosted-art-2x.swift -o "$out/repro"
codesign -s - --force "$out/repro" 2>/dev/null || true
echo "host $(hostname) $(sw_vers -productVersion)"
GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh /bin/bash -c '
  out="$1"
  "$out/VDisplay.app/Contents/MacOS/VDisplay" 60 600 main 1920x1200 hidpi > "$out/vdisplay.log" 2>&1 &
  vd=$!
  for _ in $(seq 90); do grep -q "^ready" "$out/vdisplay.log" && break; sleep 1; done
  echo "vdisplay: $(cat "$out/vdisplay.log" | tail -3)"
  for mode in none filters filters-sublayer blur blur-sublayer blur-outset blur-outset-view preblur; do
    perl -e "alarm 60; exec @ARGV" "$out/repro" "$mode" "$out" || echo "RESULT mode=$mode exited $?"
  done
  kill "$vd" 2>/dev/null || true
' _ "$out" 2>&1 | tee "$out/run.log"
tar -czf "$out/frosted-art-2x.tar.gz" -C "$out" $(cd "$out" && ls *.png run.log vdisplay.log 2>/dev/null)
grep '^RESULT' "$out/run.log" || { echo "frosted-art-2x: no results" >&2; exit 1; }
