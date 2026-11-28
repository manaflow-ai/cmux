#!/usr/bin/env bash
# cargo-groups.sh sizes CARGO_BUILD_JOBS from the cores its cgroup's memory can hold: a pool slot that sees all 96
# host threads under MemoryMax 24G gave group 1 96 jobs and nine more groups 20 each, and the kernel SIGKILLed the
# fat-LTO cmux-tui rustc (cmux-tui job 140826310692, 2026-11-28). It also holds to the host's MemAvailable: an
# uncapped 16-thread GCE pool slot sharing its VM ran 46 tokens and lost the fat-LTO acpmux and cmux-tui-core rustc
# to SIGKILL (cmux-tui-artifacts job 140972969989, 2026-11-28), and a SIGKILLed group says it ran out of memory.
# A fake cgroup tree, /proc/meminfo, /proc/vmstat and getconf stand in.
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
meminfo() { printf 'MemTotal: %d kB\nMemFree: 1 kB\nMemAvailable: %d kB\n' $(($1 * 1048576)) $(($2 * 1048576)) > "$tmp/meminfo"; }
meminfo 512 500 # memory to spare unless a case says otherwise
echo "oom_kill 3" > "$tmp/vmstat"
export PATH="$tmp/bin:$PATH" CARGO_GROUPS_CGROUP_ROOT="$tmp/cg" CARGO_GROUPS_PROC_CGROUP="$tmp/proc-cgroup" \
  CARGO_GROUPS_MEMINFO="$tmp/meminfo" CARGO_GROUPS_VMSTAT="$tmp/vmstat"
unset CARGO_BUILD_JOBS GITHUB_ACTIONS || true

run() { bash "$script" "$tmp/target" x86_64-unknown-linux-gnu "" "echo a" "" "echo b" "" "echo c" "" "echo d" 2>&1; }

# 1. A 24 GiB slot under a 112 GiB slice on a 96-thread host: 8 cores, not 96.
echo $((24 * 1073741824)) > "$tmp/cg/ci.slice/r2.service/memory.max"
out=$(run)
grep -q 'memory.max 24 GiB holds 8 of 96 cores' <<<"$out" || { echo "$out"; echo "FAIL: no memory cap line"; exit 1; }
grep -q 'CARGO_BUILD_JOBS=6 for group 1, 2 each for the others' <<<"$out" || { echo "$out"; echo "FAIL: jobs not capped"; exit 1; }

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
# (Both words above are assignments, so the override stayed in the shell: put the real path back.)
CARGO_GROUPS_PROC_CGROUP="$tmp/proc-cgroup"

# 4. A caller's CARGO_BUILD_JOBS still wins.
echo $((24 * 1073741824)) > "$tmp/cg/ci.slice/r2.service/memory.max"
out=$(CARGO_BUILD_JOBS=5 run)
grep -q 'CARGO_BUILD_JOBS=5 each' <<<"$out" || { echo "$out"; echo "FAIL: caller's jobs overridden"; exit 1; }

# 5. No memory.max, but the VM's sibling slot holds most of its RAM (64 GiB, 20 available): 6 of 16 cores.
echo max > "$tmp/cg/ci.slice/r2.service/memory.max"; echo max > "$tmp/cg/ci.slice/memory.max"
meminfo 62 20
out=$(FAKE_NPROC=16 run)
grep -q 'memory: memory.max none GiB, MemTotal 62 GiB, MemAvailable 20 GiB, 16 cores' <<<"$out" || { echo "$out"; echo "FAIL: no memory line"; exit 1; }
grep -q 'MemAvailable 20 GiB holds 6 of 16 cores' <<<"$out" || { echo "$out"; echo "FAIL: MemAvailable not used"; exit 1; }
grep -q 'CARGO_BUILD_JOBS=4 for group 1, 2 each for the others' <<<"$out" || { echo "$out"; echo "FAIL: jobs not capped by MemAvailable"; exit 1; }

# 6. memory.max under MemAvailable still wins.
echo $((24 * 1073741824)) > "$tmp/cg/ci.slice/r2.service/memory.max"; meminfo 512 300
out=$(run)
grep -q 'memory.max 24 GiB holds 8 of 96 cores' <<<"$out" || { echo "$out"; echo "FAIL: memory.max not the lesser budget"; exit 1; }

# 8. The pool slot that OOM-killed the Cloud machine channel's x86_64 build (8 threads, memory.max 14 GiB, 5
# groups; cmux-machine-channel run 46144424122, 2026-11-28): 7 tokens in all, not 4 + 4 x 2 = 12, and (run 46151055767, where seven one-token groups
# still lost the acpmux rustc) only 14 / 4 = 3 groups at once: 3 + 2 x 2 tokens.
echo $((14 * 1073741824)) > "$tmp/cg/ci.slice/r2.service/memory.max"; meminfo 512 500
out=$(FAKE_NPROC=8 bash "$script" "$tmp/target" x86_64-unknown-linux-gnu "" "echo a" "" "echo b" "" "echo c" "" "echo d" "" "echo e" 2>&1)
grep -q 'memory.max 14 GiB holds 7 tokens across 3 of 5 groups at once, 2 GiB a token, 4 GiB a group' <<<"$out" || { echo "$out"; echo "FAIL: no token budget line"; exit 1; }
grep -q 'CARGO_BUILD_JOBS=3 for group 1, 2 each for the others' <<<"$out" || { echo "$out"; echo "FAIL: token sum over the budget"; exit 1; }
conc="$tmp/conc"; : > "$conc"
g='echo start >> '"$conc"'; sleep 0.4; echo end >> '"$conc"
FAKE_NPROC=8 bash "$script" "$tmp/target" x86_64-unknown-linux-gnu "" "$g" "" "$g" "" "$g" "" "$g" "" "$g" >/dev/null 2>&1 || { echo "FAIL: capped groups failed"; exit 1; }
peak=$(awk '/start/{n++; if(n>m)m=n} /end/{n--} END{print m}' "$conc")
((peak == 3)) || { echo "FAIL: $peak groups at once under a 14 GiB cap, want 3"; exit 1; }

# 7. The OOM detector: a SIGKILLed group while oom_kill rises is named out of memory; a compile error is not.
kill9='echo "process did not exit successfully: rustc (signal: 9, SIGKILL: kill)"; echo "oom_kill 5" > '"$tmp/vmstat"'; exit 101'
echo "oom_kill 3" > "$tmp/vmstat"
out=$(bash "$script" "$tmp/target" x86_64-unknown-linux-gnu "" "echo a" "" "$kill9" 2>&1) && { echo "$out"; echo "FAIL: a killed group passed"; exit 1; }
grep -q '::error title=cargo groups out of memory::cargo group(s) 2 lost a process to SIGKILL; the kernel OOM-killed 2 process(es)' <<<"$out" || { echo "$out"; echo "FAIL: no OOM error"; exit 1; }
out=$(bash "$script" "$tmp/target" x86_64-unknown-linux-gnu "" "echo a" "" "echo 'error[E0308]: mismatched types'; exit 101" 2>&1) && { echo "$out"; echo "FAIL: a failed group passed"; exit 1; }
! grep -q 'out of memory' <<<"$out" || { echo "$out"; echo "FAIL: a compile error called OOM"; exit 1; }
grep -q 'error: cargo group(s) 2 failed' <<<"$out" || { echo "$out"; echo "FAIL: no failure line"; exit 1; }

# 9. OOM_RERUN_ALONE: a group the kernel OOM-killed reruns once alone and passes when the rerun fits (the survivor
# twin finished, so only the killed crate builds again); a group killed twice still fails (case 7).
mark="$tmp/killed-once"; rm -f "$mark"
once='if [ ! -e '"$mark"' ]; then : > '"$mark"'; echo "process did not exit successfully: rustc (signal: 9, SIGKILL: kill)"; echo "oom_kill 9" > '"$tmp/vmstat"'; exit 101; fi; echo "built on the rerun"'
echo "oom_kill 3" > "$tmp/vmstat"
out=$(bash "$script" "$tmp/target" x86_64-unknown-linux-gnu "" "$once" "" "echo b" 2>&1) || { echo "$out"; echo "FAIL: an OOM-killed group did not pass on its rerun"; exit 1; }
grep -q 'cargo group 1 (): the kernel OOM-killed a process (exit 101); rerunning it once alone' <<<"$out" || { echo "$out"; echo "FAIL: no rerun line"; exit 1; }
grep -q 'built on the rerun' <<<"$out" || { echo "$out"; echo "FAIL: the rerun did not run"; exit 1; }
grep -q 'cargo group 1 () rerun: [0-9]* s' <<<"$out" || { echo "$out"; echo "FAIL: no rerun time"; exit 1; }
! grep -q 'out of memory' <<<"$out" || { echo "$out"; echo "FAIL: a passing rerun still reported OOM"; exit 1; }
# The rerun builds one unit at a time: CARGO_BUILD_JOBS=1 (the first run had more).
mark2="$tmp/rerun-jobs-mark"
jobs_cmd='if [ ! -e '"$mark2"' ]; then : > '"$mark2"'; echo "jobs first $CARGO_BUILD_JOBS"; echo "rustc (signal: 9, SIGKILL: kill)"; echo "oom_kill 11" > '"$tmp/vmstat"'; exit 101; fi; echo "jobs rerun $CARGO_BUILD_JOBS"'
echo "oom_kill 10" > "$tmp/vmstat"
out=$(bash "$script" "$tmp/target" x86_64-unknown-linux-gnu "" "$jobs_cmd" "" "echo b" 2>&1) || { echo "$out"; echo "FAIL: jobs rerun did not pass"; exit 1; }
grep -q 'jobs rerun 1$' <<<"$out" || { echo "$out"; echo "FAIL: the rerun was not CARGO_BUILD_JOBS=1"; exit 1; }
out=$(bash "$script" "$tmp/target" x86_64-unknown-linux-gnu "" "echo a" "" "echo 'error[E0308]: mismatched types'; exit 101" 2>&1) || true
! grep -q 'rerunning' <<<"$out" || { echo "$out"; echo "FAIL: a compile error was rerun"; exit 1; }

echo PASS
