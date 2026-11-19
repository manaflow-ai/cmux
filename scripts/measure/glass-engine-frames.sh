#!/usr/bin/env bash
# Fleet entry for the glass engine bench (webviews/bench/glass-engine.bench.ts): the lens as it ships against the glass
# engine, per frame on the host's GPU, at 1440x900@2 and 3840x2160 device px (1920x1080@2), with 3 and 32 glass. The
# bench starts the installed Google Chrome itself (ANGLE on Metal, a fresh profile, no automation: no Playwright on
# Macs), first headless (the viewport exactly the asked size whatever the screen), then headful in the console
# session (the display's own refresh paces the moving frames). It opens a window, so it runs alone on a display worker:
#   cmux-ci run --class exclusive --display --measurement --label measure --script scripts/measure/glass-engine-frames.sh \
#     --ref <sha> --artifact artifacts/glass-engine-frames.tar.gz [--arg=rounds=20] [--arg=paced=600] [--arg=modes=lens:24]
# The artifact holds headless.json, headful.json (every row: cost p50/p95/p99, moving frame p50/p95/max, fps, dropped
# frames, the WebGL renderer string, host) and the host's display and GPU. The step exits 0 when the headless run
# measured; GLASS-ENGINE-FRAMES lines in the log are the rows.
set -uo pipefail
rounds=20 paced=600 modes="lens:0,lens:24,spectrum:24" chips="1,30" sizes="1440x900@2,1920x1080@2"
for arg in "$@"; do
  case "$arg" in
    rounds=*) rounds="${arg#rounds=}" ;;
    paced=*) paced="${arg#paced=}" ;;
    modes=*) modes="${arg#modes=}" ;;
    chips=*) chips="${arg#chips=}" ;;
    sizes=*) sizes="${arg#sizes=}" ;;
    *) echo "glass-engine-frames.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$rounds" =~ ^[0-9]{1,3}$ && "$paced" =~ ^[0-9]{1,5}$ ]] || { echo "glass-engine-frames.sh: rounds=1-999 paced=0-99999" >&2; exit 2; }
[[ "$modes" =~ ^[a-z]+:[0-9]+(,[a-z]+:[0-9]+)*$ && "$chips" =~ ^[0-9]+(,[0-9]+)*$ && "$sizes" =~ ^[0-9]+x[0-9]+@[0-9.]+(,[0-9]+x[0-9]+@[0-9.]+)*$ ]] \
  || { echo "glass-engine-frames.sh: modes=MODE:BLUR,... chips=N,... sizes=WxH@DPR,..." >&2; exit 2; }
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/artifacts/glass-engine-frames"
rm -rf "$out" && mkdir -p "$out"
cd "$root/webviews" || exit 1
bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null 2>&1
{
  echo "host: $(hostname -s)"
  sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m
  sw_vers 2>/dev/null || uname -sr
  system_profiler SPDisplaysDataType 2>/dev/null
} > "$out/host.txt"
grep -E "host:|Apple M|Chipset Model|Resolution|Refresh|ProductVersion" "$out/host.txt" | sed 's/^ */glass-engine-frames: /'
export ROUNDS="$rounds" PACED="$paced" MODES="$modes" CHIPS="$chips" SIZES="$sizes" BROWSER=chrome
status=0
for mode in headless headful; do
  echo "glass-engine-frames: chrome $mode"
  CHROME_MODE="$mode" LABEL="$mode" OUT="$out/$mode.json" bun bench/glass-engine.bench.ts "$rounds" > "$out/$mode.stdout" 2> "$out/$mode.log"
  code=$?
  cat "$out/$mode.log"
  if [[ -f "$out/$mode.json" ]]; then
    python3 -c 'import json,sys
for row in json.load(open(sys.argv[1])): print("GLASS-ENGINE-FRAMES", json.dumps(row, sort_keys=True))' "$out/$mode.json"
  fi
  [[ "$mode" == headless && $code -ne 0 ]] && status=$code
done
tar -czf "$root/artifacts/glass-engine-frames.tar.gz" -C "$root/artifacts" glass-engine-frames
exit "$status"
