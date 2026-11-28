#!/usr/bin/env bash
# cargo-mem-jobs.sh: print the cargo job count this runner's memory holds, or nothing when every visible core fits.
# A pool slot sees every host thread under a cgroup v2 memory.max (MemoryMax 24G on a 96-thread host); a cold debug
# `cargo build -p cmux-tui` at -j96 there had the kernel SIGKILL the acpmux and cmux-tui rustc (repro-capsule
# journey jobs 140974814625 and 140983092431, 2026-11-28). One core per CARGO_GROUPS_GIB_PER_CORE (3) GiB of the
# smallest memory.max on this process's cgroup path, the same rule as cargo-groups.sh (which a later change can
# fold this into). A caller's CARGO_BUILD_JOBS wins. A single cargo build step uses it as
#   CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(bash scripts/ci/cargo-mem-jobs.sh 2>/dev/null || true)}"
# CARGO_GROUPS_CGROUP_ROOT and CARGO_GROUPS_PROC_CGROUP move /sys/fs/cgroup and /proc/self/cgroup for tests.
set -euo pipefail

if [[ -n "${CARGO_BUILD_JOBS:-}" ]]; then echo "$CARGO_BUILD_JOBS"; exit 0; fi

root="${CARGO_GROUPS_CGROUP_ROOT:-/sys/fs/cgroup}"
rel=$(awk -F: '$1 == "0" { print $3; exit }' "${CARGO_GROUPS_PROC_CGROUP:-/proc/self/cgroup}" 2>/dev/null) || exit 0
[[ -n "$rel" ]] || exit 0
p="$root${rel%/}" min=""
while :; do
  v=$(cat "$p/memory.max" 2>/dev/null) || v=""
  if [[ "$v" =~ ^[0-9]+$ ]] && { [[ -z "$min" ]] || ((v < min)); }; then min=$v; fi
  [[ "$p" == "$root" || "$p" != */* ]] && break
  p="${p%/*}"; [[ -n "$p" ]] || p=/
  [[ "$p" == "$root"* ]] || break
done
[[ -n "$min" ]] || exit 0
cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
fit=$(((min / 1073741824) / ${CARGO_GROUPS_GIB_PER_CORE:-3})); ((fit >= 1)) || fit=1
if ((fit < cores)); then
  echo "cargo-mem-jobs: memory.max $((min / 1073741824)) GiB holds $fit of $cores cores" >&2
  echo "$fit"
fi
