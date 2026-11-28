#!/usr/bin/env bash
# cargo-mem-jobs.sh caps a single cargo build at the cores its cgroup's memory holds: a cold debug cmux-tui build at
# -j96 in a 24 GiB pool slot had its acpmux rustc SIGKILLed (repro-capsule journey job 140983092431, 2026-11-28).
# --gib-per-job/--max size the cmux_next_ daemon tests, whose acpmux and cmux-tui-core rustc were both SIGKILLed at a
# fixed -j2 in that slot (PR pipeline runs 46151362183 and 46159118214). A fake cgroup tree, meminfo and getconf
# stand in.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../cargo-mem-jobs.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/cg/ci.slice/r2.service"
printf '#!/bin/sh\necho "${FAKE_NPROC:-96}"\n' > "$tmp/bin/getconf"; chmod +x "$tmp/bin/getconf"
echo "0::/ci.slice/r2.service" > "$tmp/proc-cgroup"
echo max > "$tmp/cg/memory.max"
echo $((112 * 1073741824)) > "$tmp/cg/ci.slice/memory.max"
echo "MemTotal:       $((512 * 1048576)) kB" > "$tmp/meminfo"
export PATH="$tmp/bin:$PATH" CARGO_GROUPS_CGROUP_ROOT="$tmp/cg" CARGO_GROUPS_PROC_CGROUP="$tmp/proc-cgroup"
export CARGO_GROUPS_MEMINFO="$tmp/meminfo"
unset CARGO_BUILD_JOBS CARGO_GROUPS_GIB_PER_CORE || true
check() { [[ "$2" == "$3" ]] || { echo "FAIL: $1: got '$2', want '$3'"; exit 1; }; }

# 1. A 24 GiB slot under a 112 GiB slice on a 96-thread host: 8.
echo $((24 * 1073741824)) > "$tmp/cg/ci.slice/r2.service/memory.max"
check "24 GiB slot" "$(bash "$script" 2>/dev/null)" 8
# 2. Memory to spare (16 cores, 64 GiB): nothing, so cargo keeps every core.
echo $((64 * 1073741824)) > "$tmp/cg/ci.slice/r2.service/memory.max"
check "memory to spare" "$(FAKE_NPROC=16 bash "$script" 2>/dev/null)" ""
# 3. No limit anywhere, or no /proc cgroup: nothing.
echo max > "$tmp/cg/ci.slice/r2.service/memory.max"; echo max > "$tmp/cg/ci.slice/memory.max"
check "uncapped" "$(bash "$script" 2>/dev/null)" ""
check "no cgroup file" "$(CARGO_GROUPS_PROC_CGROUP="$tmp/none" bash "$script" 2>/dev/null)" ""
# 4. A tiny cap still gives one job; a caller's CARGO_BUILD_JOBS wins.
echo $((2 * 1073741824)) > "$tmp/cg/ci.slice/r2.service/memory.max"
check "2 GiB" "$(bash "$script" 2>/dev/null)" 1
check "caller" "$(CARGO_BUILD_JOBS=5 bash "$script" 2>/dev/null)" 5
# 5. No cgroup limit on a small VM: MemTotal caps it (16 GiB, 8 cores: 5 fits, so nothing; 4 GiB: 1).
echo max > "$tmp/cg/ci.slice/r2.service/memory.max"
echo "MemTotal:       $((16 * 1048576)) kB" > "$tmp/meminfo"
check "16 GiB VM" "$(FAKE_NPROC=4 bash "$script" 2>/dev/null)" ""
echo "MemTotal:       $((4 * 1048576)) kB" > "$tmp/meminfo"
check "4 GiB VM" "$(FAKE_NPROC=8 bash "$script" 2>/dev/null)" 1
echo "MemTotal:       $((512 * 1048576)) kB" > "$tmp/meminfo"
# 6. --gib-per-job 16 --max 2 (the daemon tests): a 24 GiB slot gets 1, a 64 GiB slot 2 (the cap), a 2-core host
#    at most 2, and with no memory figure at all the cap.
echo $((24 * 1073741824)) > "$tmp/cg/ci.slice/r2.service/memory.max"
check "daemon 24 GiB" "$(bash "$script" --gib-per-job 16 --max 2 2>/dev/null)" 1
echo $((64 * 1073741824)) > "$tmp/cg/ci.slice/r2.service/memory.max"
check "daemon 64 GiB" "$(bash "$script" --gib-per-job 16 --max 2 2>/dev/null)" 2
check "daemon 1 core" "$(FAKE_NPROC=1 bash "$script" --gib-per-job 16 --max 2 2>/dev/null)" 1
check "daemon unknown" "$(CARGO_GROUPS_PROC_CGROUP="$tmp/none" CARGO_GROUPS_MEMINFO="$tmp/none" \
  bash "$script" --gib-per-job 16 --max 2 2>/dev/null)" 2
check "daemon caller" "$(CARGO_BUILD_JOBS=3 bash "$script" --gib-per-job 16 --max 2 2>/dev/null)" 3

echo PASS
