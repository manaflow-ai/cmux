#!/usr/bin/env bash
# Which 2x (HiDPI) virtual display a fleet Mac brings up: the Liquid Glass Parity matrix's 2x cells need one
# (scripts/measure/glass-parity.sh), and aws-m4pro-7 offered no mode at all for 1920x1200 points at 2x
# (3840x2400 pixels; runs 1-10). Starts scripts/ci/frame-pacing/vdisplay.m in the console user's GUI session
# for each size and mode form, holds it 1 s, and prints its output; a line "PROBE size form scale=2" is a
# display that came up at 2x.
#   cmux-ci run --class exclusive --measurement --label measure --target-worker HOST --pin-strict \
#     --script scripts/measure/vdisplay-hidpi-probe.sh --ref <a feat-cmux-next sha with this script>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
out="$(pwd)/artifacts/vdisplay-probe"
mkdir -p "$out/VDisplay.app/Contents/MacOS"
xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework AppKit -framework CoreVideo \
  scripts/ci/frame-pacing/vdisplay.m -o "$out/VDisplay.app/Contents/MacOS/VDisplay"
cp scripts/ci/frame-pacing/VDisplay-Info.plist "$out/VDisplay.app/Contents/Info.plist"
codesign -s - --force "$out/VDisplay.app" 2>/dev/null || true
echo "host $(hostname) $(sw_vers -productVersion) $(sysctl -n machdep.cpu.brand_string)"
system_profiler SPDisplaysDataType 2>/dev/null | sed -n '1,30p' || true
for size in 1920x1200 1920x1080 1600x1000 1440x900 1280x800; do
  for form in hidpi hidpi-points; do
    log="$out/$size-$form.log"
    GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh \
      "$out/VDisplay.app/Contents/MacOS/VDisplay" 60 1 main "$size" "$form" > "$log" 2>&1 || true
    scale="$(sed -n 's/^ready .* scale=\([0-9]*\).*/\1/p' "$log" | tail -1)"
    echo "PROBE $size $form scale=${scale:-none}"
    sed 's/^/  /' "$log" | cut -c1-400
  done
done
