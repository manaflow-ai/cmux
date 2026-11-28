#!/usr/bin/env bash
# cargo-mem-jobs.sh: print the cargo job count this runner's memory holds, or nothing when every visible core fits.
# A pool slot sees every host thread under a cgroup v2 memory.max (MemoryMax 24G on a 96-thread host); a cold debug
# `cargo build -p cmux-tui` at -j96 there had the kernel SIGKILL the acpmux and cmux-tui rustc (repro-capsule
# journey jobs 140974814625 and 140983092431, 2026-11-28). One core per CARGO_GROUPS_GIB_PER_CORE (3) GiB of the
# smallest memory.max on this process's cgroup path, or of MemTotal when that is smaller, the same rule as
# cargo-groups.sh (which a later change can fold this into). A caller's CARGO_BUILD_JOBS wins. A single cargo build
# step uses it as
#   CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(bash scripts/ci/cargo-mem-jobs.sh 2>/dev/null || true)}"
#
#   cargo-mem-jobs.sh --gib-per-job G --max N
#       always prints a count: the jobs at G GiB each that the memory holds, at most N and the visible cores, at least
#       1. For builds whose big crates each want far more than 3 GiB: the cmux_next_ daemon tests compile acpmux and
#       cmux-tui-core side by side, and at a fixed -j2 both rustc were SIGKILLed in a 24 GiB pool slot (PR pipeline
#       runs 46151362183 and 46159118214, 2026-11-28).
# CARGO_GROUPS_CGROUP_ROOT, CARGO_GROUPS_PROC_CGROUP and CARGO_GROUPS_MEMINFO move /sys/fs/cgroup, /proc/self/cgroup
# and /proc/meminfo for tests.
set -euo pipefail

gib="${CARGO_GROUPS_GIB_PER_CORE:-3}" max=""
while (($#)); do
  case "$1" in
    --gib-per-job) gib="${2:?--gib-per-job needs G}"; shift 2 ;;
    --max) max="${2:?--max needs N}"; shift 2 ;;
    *) echo "usage: $0 [--gib-per-job G] [--max N]" >&2; exit 2 ;;
  esac
done

if [[ -n "${CARGO_BUILD_JOBS:-}" ]]; then echo "$CARGO_BUILD_JOBS"; exit 0; fi

cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
# With --max, a count always prints: the cap, or the cores when fewer, when no memory figure can be read.
fallback() { if [[ -n "$max" ]]; then echo $((max < cores ? max : cores)); fi; exit 0; }

min=""
root="${CARGO_GROUPS_CGROUP_ROOT:-/sys/fs/cgroup}"
rel=$(awk -F: '$1 == "0" { print $3; exit }' "${CARGO_GROUPS_PROC_CGROUP:-/proc/self/cgroup}" 2>/dev/null) || rel=""
if [[ -n "$rel" ]]; then
  p="$root${rel%/}"
  while :; do
    v=$(cat "$p/memory.max" 2>/dev/null) || v=""
    if [[ "$v" =~ ^[0-9]+$ ]] && { [[ -z "$min" ]] || ((v < min)); }; then min=$v; fi
    [[ "$p" == "$root" || "$p" != */* ]] && break
    p="${p%/*}"; [[ -n "$p" ]] || p=/
    [[ "$p" == "$root"* ]] || break
  done
fi
total=$(awk '$1 == "MemTotal:" { print $2 * 1024; exit }' "${CARGO_GROUPS_MEMINFO:-/proc/meminfo}" 2>/dev/null) || total=""
if [[ "$total" =~ ^[0-9]+$ ]] && { [[ -z "$min" ]] || ((total < min)); }; then min=$total; fi
[[ -n "$min" ]] || fallback

fit=$(((min / 1073741824) / gib)); ((fit >= 1)) || fit=1
if [[ -n "$max" ]]; then
  jobs=$fit; ((jobs <= max)) || jobs=$max; ((jobs <= cores)) || jobs=$cores
  echo "cargo-mem-jobs: memory $((min / 1073741824)) GiB at $gib GiB a job holds $fit; $jobs of $cores cores (at most $max)" >&2
  echo "$jobs"
elif ((fit < cores)); then
  echo "cargo-mem-jobs: memory $((min / 1073741824)) GiB holds $fit of $cores cores" >&2
  echo "$fit"
fi
