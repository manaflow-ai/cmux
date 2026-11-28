#!/usr/bin/env bash
# cargo-groups.sh sizes CARGO_BUILD_JOBS from the cores its cgroup's memory can hold: a pool slot that sees all 96
# host threads under MemoryMax 24G gave group 1 96 jobs and nine more groups 20 each, and the kernel SIGKILLed the
# fat-LTO cmux-tui rustc (cmux-tui job 140826310692, 2026-11-28). A fake cgroup tree and getconf stand in.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../cargo-groups.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/cg/ci.slice/r2.service"
printf '#!/bin/sh\necho "${FAKE_NPROC:-96}"\n' > "$tmp/bin/getconf"; chmod +x "$tmp/bin/getconf"
echo "0::/ci.slice/r2.service" > "$tmp/proc-cgroup"
echo max > "$tmp/cg/memory.max" 2>/dev/null || true
echo $((112 * 1073741824)) > "$tmp/cg/ci.slice/memory.max"
export PATH="$tmp/bin:$PATH" CARGO_GROUPS_CGROUP_ROOT="$tmp/cg" CARGO_GROUPS_PROC_CGROUP="$tmp/proc-cgroup"
unset CARGO_BUILD_JOBS GITHUB_ACTIONS || true

run() { bash "$script" "$tmp/target" x86_64-unknown-linux-gnu "" "echo a" "" "echo b" "" "echo c" "" "echo d" 2>&1; }

# 1. A 24 GiB slot under a 112 GiB slice on a 96-thread host: 8 cores, not 96.
echo $((24 * 1073741824)) > "$tmp/cg/ci.slice/r2.service/memory.max"
out=$(run)
grep -q 'memory.max 24 GiB holds 8 of 96 cores' <<<"$out" || { echo "$out"; echo "FAIL: no memory cap line"; exit 1; }
grep -q 'CARGO_BUILD_JOBS=8 for group 1, 4 each for the others' <<<"$out" || { echo "$out"; echo "FAIL: jobs not capped"; exit 1; }

# 2. Memory to spare (16 cores, 64 GiB): every core, no cap line.
echo $((64 * 1073741824)) > "$tmp/cg/ci.slice/r2.service/memory.max"
out=$(FAKE_NPROC=16 run)
! grep -q 'holds' <<<"$out" || { echo "$out"; echo "FAIL: capped a runner with memory to spare"; exit 1; }
grep -q 'CARGO_BUILD_JOBS=16 for group 1, 8 each for the others' <<<"$out" || { echo "$out"; echo "FAIL: cores changed"; exit 1; }

# 3. No cgroup limit anywhere (a Mac, an uncapped VM): unchanged.
echo max > "$tmp/cg/ci.slice/r2.service/memory.max"; echo max > "$tmp/cg/ci.slice/memory.max"
out=$(run)
grep -q 'CARGO_BUILD_JOBS=96 for group 1, 48 each for the others' <<<"$out" || { echo "$out"; echo "FAIL: uncapped runner changed"; exit 1; }
CARGO_GROUPS_PROC_CGROUP="$tmp/none" out=$(run)
grep -q 'CARGO_BUILD_JOBS=96 for group 1' <<<"$out" || { echo "$out"; echo "FAIL: no /proc cgroup changed"; exit 1; }

# 4. A caller's CARGO_BUILD_JOBS still wins.
echo $((24 * 1073741824)) > "$tmp/cg/ci.slice/r2.service/memory.max"
out=$(CARGO_BUILD_JOBS=5 run)
grep -q 'CARGO_BUILD_JOBS=5 each' <<<"$out" || { echo "$out"; echo "FAIL: caller's jobs overridden"; exit 1; }

echo PASS
