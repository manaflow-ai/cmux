#!/usr/bin/env bash
# Reproduces the Chromium allocator zone race that crashed cmux-next with
# "[FATAL:allocator_shim_apple.cc(61)] ... No zone found" and checks the fix
# (plans/cmux-next/browser-isolation.md, "Allocator zone race").
#
# Four threads malloc/free while the main thread dlopens the Chromium
# framework (as CEFRuntime.loadLibrary does off the main thread).
#   late:  no early zone; PartitionAlloc's constructor briefly unregisters the
#          system zone and a concurrent free() finds no owner (expected crashes)
#   early: CmuxNextMallocZone installed first (what CmuxNextApp.main does)
#
# Usage: run.sh [runs] [framework binary]   (default: the pinned cached CEF)
#        run.sh corrupt [runs] [framework binary] [seconds]
#   corrupt (#23821): corrupt.c with the early zone, under libmalloc's heap checks
#          (MallocCheckHeapStart=1 MallocCheckHeapEach=100 MallocScribble=1, and
#          MallocStackLogging so a report names the allocation): a background thread dlopens
#          the framework while the main thread churns canary-filled blocks. Counts runs that
#          saw a changed live block (exit 2) or that libmalloc ended (any other failure), and
#          prints the first failure's output. Exit 0 when every run was clean.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
mode=race
if [[ "${1:-}" == corrupt ]]; then mode=corrupt; shift; fi
runs="${1:-30}"
version="$(/usr/bin/plutil -extract version raw -o - "$root/scripts/cmux-next/cef-manifest.json")"
framework="${2:-$HOME/Library/Caches/cmux/cef/$version/Chromium Embedded Framework.framework/Chromium Embedded Framework}"
[[ -f "$framework" ]] || { echo "skip: no CEF framework at $framework (run scripts/cmux-next/ensure-cef.sh)"; exit 0; }
zone="$root/Packages/macOS/CmuxNext/Sources/CmuxNextMallocZone"
if [[ "$mode" == corrupt ]]; then
  seconds="${3:-1}"
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  clang -O1 -g -I"$zone/include" "$here/corrupt.c" "$zone/early_zone.c" -o "$dir/corrupt"
  corrupt=0 ended=0 first=""
  for run in $(seq 1 "$runs"); do
    status=0
    MallocCheckHeapStart=1 MallocCheckHeapEach=100 MallocScribble=1 MallocStackLogging=1 \
      "$dir/corrupt" "$framework" "$seconds" > "$dir/out" 2>&1 || status=$?
    [[ "$status" -eq 0 ]] && continue
    if [[ "$status" -eq 2 ]]; then corrupt=$((corrupt + 1)); else ended=$((ended + 1)); fi
    [[ -n "$first" ]] || first="run $run exit $status: $(tail -c 4000 "$dir/out")"
  done
  echo "corrupt: $runs runs: $corrupt saw a changed live block, $ended ended by libmalloc or a signal"
  [[ -z "$first" ]] || printf 'first failure: %s\n' "$first"
  [[ "$corrupt" -eq 0 && "$ended" -eq 0 ]]
  exit
fi
bin="$(mktemp -d)/repro"
clang -O2 -I"$zone/include" "$here/repro.c" "$zone/early_zone.c" -o "$bin"
late=0; early=0
for _ in $(seq 1 "$runs"); do
  ("$bin" late "$framework") >/dev/null 2>&1 || late=$((late + 1))
  ("$bin" early "$framework") >/dev/null 2>&1 || early=$((early + 1))
done
rm -rf "$(dirname "$bin")"
echo "without early zone: $late/$runs crashed; with early zone: $early/$runs crashed"
[[ "$early" -eq 0 ]]
