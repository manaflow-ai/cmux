#!/usr/bin/env bash
# The dev-loop ceiling (cmuxterm-hq goals/dev-loop-ceiling.md): runs each loop's measurement on this Mac, then
# scripts/measure/dev-loop/bound.py, which writes OUT/report.json with each loop's p50 over its simulated stage-floor
# bound and the worst of them (the goal holds it at 2x or under). Leo: "Dev loop at its theoretical ceiling: a
# measured and simulated bound for edit-to-running (web swap, daemon restart, Swift inject, startup-time loop)
# published, and the measured p50 within 2x of that bound".
#   scripts/measure/dev-loop-ceiling.sh OUT [N] [LOOPS]
# N: edit rounds per loop (default 5). LOOPS: comma list (default all four). A loop whose script is missing or fails
# is reported UNMEASURED (its log is OUT/<loop>.log) and the others still run. Exit 0 only when every loop measured.
set -uo pipefail
out="${1:?usage: dev-loop-ceiling.sh OUT [N] [LOOPS]}"
n="${2:-5}"
loops="${3:-web_swap,daemon_restart,swift_inject,startup_loop}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
here="$root/scripts/measure/dev-loop"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
cd "$root"
# A fleet step checks out no submodules (only their empty gitlink directories), and every loop builds the app:
# reload.sh needs Ghostty's headers and the ghostty-next tree, and GhosttyKit.xcframework (a prebuilt download).
# 2026-11-21 step 8c4a9182f450ab59d9b0a93c: "ghostty/include/ghostty.h is missing. Run ./scripts/setup.sh".
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub" || { echo "dev-loop-ceiling: submodule $sub failed" >&2; exit 1; }
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh || { echo "dev-loop-ceiling: GhosttyKit download failed" >&2; exit 1; }
fi
IFS=, read -ra list <<<"$loops"
# Each loop runs in the background, in its own process group (set -m). Every DLC_HEARTBEAT_S the step prints the
# loop's last log line, so the silence watchdog sees progress. A loop past DLC_LOOP_MAX_S is stopped and reported
# UNMEASURED, so the others and bound.py still run. 2026-11-26 step 693ee00d07850816efffd5d2: startup_loop's
# warm build printed nothing for 68 min, the controller stopped the step as hung, and no report.json came back.
beat_s="${DLC_HEARTBEAT_S:-300}"
loop_max_s="${DLC_LOOP_MAX_S:-7200}"
set -m
for loop in "${list[@]}"; do
  script="$here/$loop.sh"
  if [[ ! -x "$script" ]]; then
    printf '{"schema":"dev-loop-ceiling/loop/v1","loop":"%s","error":"no script %s"}\n' "$loop" "${script#"$root"/}" >"$out/$loop.json"
    echo "dev-loop-ceiling: $loop: no script" >&2
    continue
  fi
  start=$(date +%s)
  echo "dev-loop-ceiling: $loop (n=$n)"
  "$script" "$out" "$n" >"$out/$loop.log" 2>&1 &
  pid=$!
  next_beat=$(( start + beat_s ))
  over=""
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    now=$(date +%s)
    if (( now - start >= loop_max_s )); then
      over=1
      echo "dev-loop-ceiling: $loop ran over $loop_max_s s (DLC_LOOP_MAX_S); stopping it" >&2
      kill -TERM -- "-$pid" 2>/dev/null
      sleep 15
      kill -KILL -- "-$pid" 2>/dev/null
      break
    fi
    if (( now >= next_beat )); then
      echo "dev-loop-ceiling: $loop running $(( now - start )) s; last: $(grep -v '] ending pid ' "$out/$loop.log" | tail -1 | cut -c1-200)"
      next_beat=$(( now + beat_s ))
    fi
  done
  wait "$pid"
  rc=$?
  if [[ -n "$over" ]]; then
    printf '{"schema":"dev-loop-ceiling/loop/v1","loop":"%s","error":"ran over %s s (DLC_LOOP_MAX_S)"}\n' "$loop" "$loop_max_s" >"$out/$loop.json"
  fi
  if (( rc != 0 )); then
    echo "dev-loop-ceiling: $loop failed (exit $rc) after $(( $(date +%s) - start )) s; last lines:" >&2
    # Without cleanup's "ending pid" lines, which filled the whole tail on 2026-11-22 step a8b4d181c32ad2c06b3a0126.
    grep -v '] ending pid ' "$out/$loop.log" | tail -20 >&2
    [[ -s "$out/$loop.json" ]] || printf '{"schema":"dev-loop-ceiling/loop/v1","loop":"%s","error":"exited nonzero with no json"}\n' "$loop" >"$out/$loop.json"
  else
    echo "dev-loop-ceiling: $loop done in $(( $(date +%s) - start )) s"
  fi
done
python3 "$here/bound.py" "$out" --loops "$loops"
