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
for loop in "${list[@]}"; do
  script="$here/$loop.sh"
  if [[ ! -x "$script" ]]; then
    printf '{"schema":"dev-loop-ceiling/loop/v1","loop":"%s","error":"no script %s"}\n' "$loop" "${script#"$root"/}" >"$out/$loop.json"
    echo "dev-loop-ceiling: $loop: no script" >&2
    continue
  fi
  start=$(date +%s)
  echo "dev-loop-ceiling: $loop (n=$n)"
  if ! "$script" "$out" "$n" >"$out/$loop.log" 2>&1; then
    echo "dev-loop-ceiling: $loop failed after $(( $(date +%s) - start )) s; last lines:" >&2
    tail -20 "$out/$loop.log" >&2
    [[ -s "$out/$loop.json" ]] || printf '{"schema":"dev-loop-ceiling/loop/v1","loop":"%s","error":"exited nonzero with no json"}\n' "$loop" >"$out/$loop.json"
  else
    echo "dev-loop-ceiling: $loop done in $(( $(date +%s) - start )) s"
  fi
done
python3 "$here/bound.py" "$out" --loops "$loops"
