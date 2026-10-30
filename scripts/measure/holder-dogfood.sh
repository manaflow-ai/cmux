#!/usr/bin/env bash
# Fleet entry for the terminal holder GUI dogfood and its process and memory A/B (perf lead, holder
# item 4): builds a tagged cmux-next app at this checkout, then runs scripts/cmux-next/holder-dogfood.py
# against it once per terminal host model (hosts, then holder): light and STRESS cost, Cmd-W, Reopen
# Closed, a 256 KiB paste, SIGKILL of the holder while the app runs, quit and relaunch. Runs alone on
# the worker because it launches an app; needs a logged-in console (aws-m4pro-9, or a host that
# passes scripts/cmux-next/bench_launch.py check):
#   cmux-ci run --class exclusive --label measure --script scripts/measure/holder-dogfood.sh --ref <sha> \
#     [--target-worker aws-m4pro-9] [--arg=--models=holder] [--arg=--vdisplay=120] --artifact holder-dogfood.json
# --vdisplay=HZ runs the dogfood on a virtual main display at HZ (split-spring.sh's helper, 1920 x 1200): STRESS
# needs a 1600 x 1000 pt window, and under the Dock a 1920 x 1080 display leaves about 967 pt, so AppKit clamps it
# (cmux20-bench, 2026-10-28). Without it the dogfood runs on the host's display.
# The build bundles bin/cmux-holder only when the client build has it (an unpublished tree builds it
# with scripts/cmux-next/build-cmux-tui-client.sh); without it the daemon runs the holder built into
# cmux-tui-host, and the report names the holder executable either way.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="hldfood"
models="hosts holder"
reload_config=() vdisplay_hz=""
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --vdisplay=*) vdisplay_hz="${arg#--vdisplay=}" ;;
    --models=*) models="${arg#--models=}"; models="${models//,/ }" ;;
    *) echo "holder-dogfood.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
# A fleet step checks out no submodules (only their empty gitlink directories): the app build needs
# Ghostty's headers and the ghostty-next tree, and GhosttyKit.xcframework (a prebuilt download).
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
out="$(mktemp -d)"
# Steps run with a per-step HOME; the account's user-level tools (bun and node for the Debug
# build's web bundles) live under its real home (as perf-bench.sh).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "holder-dogfood: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
ls -l "$app/Contents/Resources/bin/" | grep -E "cmux-holder|cmux-tui-host" || echo "holder-dogfood: the bundle has no cmux-holder"
python3 scripts/cmux-next/bench_launch.py session || { echo "holder-dogfood: no GUI session on this host" >&2; exit 1; }
vdisplay_pid="" dogfood_pid="" tee_pid=""
# shellcheck disable=SC2329 # run by the traps below
stop_vdisplay() {
  if [[ -n "$dogfood_pid" ]]; then kill -TERM "$dogfood_pid" 2>/dev/null || true; wait "$dogfood_pid" 2>/dev/null || true; fi  # the dogfood this script started
  if [[ -n "$tee_pid" ]]; then wait "$tee_pid" 2>/dev/null || true; fi  # its tee ends at the fifo's EOF
  dogfood_pid="" tee_pid=""
  if [[ -n "$vdisplay_pid" ]]; then kill "$vdisplay_pid" 2>/dev/null || true; wait "$vdisplay_pid" 2>/dev/null || true; fi  # the helper this script started
  vdisplay_pid=""
}
trap stop_vdisplay EXIT
# A cancelled step (TERM, INT or HUP) stops the dogfood and the helper at once (the dogfood runs in the
# background and is waited for, so the trap runs between commands); SIGKILL leaves the helper to its own hold.
trap 'stop_vdisplay; exit 143' TERM
trap 'stop_vdisplay; exit 130' INT
trap 'stop_vdisplay; exit 129' HUP
if [[ -n "$vdisplay_hz" ]]; then
  vd="$out/vdisplay"
  mkdir -p "$vd/VDisplay.app/Contents/MacOS"
  if xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework AppKit -framework CoreVideo \
      scripts/ci/frame-pacing/vdisplay.m -o "$vd/VDisplay.app/Contents/MacOS/VDisplay" 2> "$vd/clang.err"; then
    cp scripts/ci/frame-pacing/VDisplay-Info.plist "$vd/VDisplay.app/Contents/Info.plist"
    codesign -s - --force "$vd/VDisplay.app" 2>/dev/null || true
    # Held at most 2 h (the helper ends by itself even if this script is killed): both models take about 45 min.
    "$vd/VDisplay.app/Contents/MacOS/VDisplay" "$vdisplay_hz" 7200 main 1920x1200 > "$vd/out" 2> "$vd/err" &
    vdisplay_pid=$!
    for _ in $(seq 20); do
      grep -q '^ready\|^error' "$vd/out" 2>/dev/null && break
      kill -0 "$vdisplay_pid" 2>/dev/null || break
      sleep 1  # bounded wait for the helper's own ready line
    done
    echo "holder-dogfood: display: $(grep -m1 '^ready\|^error' "$vd/out" 2>/dev/null || echo 'the virtual display never reported')"
    sleep 2  # WindowServer settles the new main display before the app opens on it
  else
    echo "holder-dogfood: the virtual display helper did not compile; running on the real display"
  fi
fi
status=0
for model in $models; do
  # Both in the background through a fifo, so $! names each (bash 3.2 has no PID for a process
  # substitution) and the script waits for the log's last line before it reads the log.
  rm -f "$out/$model.fifo"; mkfifo "$out/$model.fifo"
  tee "$out/$model.log" < "$out/$model.fifo" &
  tee_pid=$!
  python3 scripts/cmux-next/holder-dogfood.py --app "$app" --model "$model" --out "$out/$model" > "$out/$model.fifo" &
  dogfood_pid=$!
  wait "$dogfood_pid" || status=$?
  dogfood_pid=""
  wait "$tee_pid" || status=$?
  tee_pid=""
  rm -f "$out/$model.fifo"
done
python3 - "$out" $models > "$PWD/holder-dogfood.json" <<'PY' || true
import json, sys
out, models = sys.argv[1], sys.argv[2:]
report = {}
for model in models:
    rows = []
    for line in open(f"{out}/{model}.log", errors="replace"):
        kind, _, rest = line.partition(" ")
        if kind in ("DOGFOOD-STEP", "DOGFOOD-COST", "STRESS-SESSION", "DOGFOOD-HANGS"):
            try:
                rows.append({"kind": kind, **json.loads(rest)})
            except ValueError:
                pass
    report[model] = rows
print(json.dumps(report, indent=1))
PY
exit "$status"
