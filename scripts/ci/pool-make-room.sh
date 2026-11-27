#!/usr/bin/env bash
# Make room on a pool host before a job step that needs more disk than the pool admits a job with.
#
# usage: scripts/ci/pool-make-room.sh NEED_BYTES [WAIT_SECONDS]
#
# Why: the pool's job-started hook (/opt/cmux-disk-floor.sh, from cmuxterm-hq's
# skills/infra/linux-runner-pool/pool.sh) cleans in line only when a job starts under one pool
# job's need, 17 GiB. Above that and under the VM's floor (17 GiB per runner), it starts its prune
# in the background, and that prune takes only the cheap steps (logs, packages, docker). It sweeps
# the VM's shared disk (every runner's sccache, idle runners' caches and checkouts) only under the
# reserve, also 17 GiB on a two-runner VM. A job that grows past 17 GiB on such a host fills the
# disk while the idle state beside it stays. That is the cross build of aarch64-apple-darwin: run
# 45793848138 (2026-11-26 09:40Z) started on cmux-runner-pool-w3a-0198 at 31.5 GiB free, under its
# 34.0 GiB floor ("pruning in the background"). The R2 target restore and the cross toolchain left
# 15.1 GiB by the build step, and cargo died "No space left on device (os error 28)" writing
# libboringtun's archive. The acpmux dev channel stayed stale behind it.
#
# So this step names the job's own need and runs the hook's prune in line with that need as both
# floor and reserve, bounded by WAIT_SECONDS (default 120). That prune is the one built to run
# beside a job: it takes only what no job holds, and another runner's caches and checkouts only
# while that runner runs no job, decided under its walk lock. Off a pool host (no hook), or with
# NEED_BYTES already free, it does nothing. It never fails the job: a host still short after the
# bound builds anyway, as before, and the job log says what was free.
#
# CMUX_POOL_DISK_FLOOR_HOOK names another hook (tests); CMUX_POOL_MAKE_ROOM_PATH the disk to measure.
set -uo pipefail

need="${1:-}"
wait_s="${2:-120}"
case "$need" in ''|*[!0-9]*) echo "usage: $0 NEED_BYTES [WAIT_SECONDS]" >&2; exit 2;; esac
case "$wait_s" in ''|*[!0-9]*) wait_s=120;; esac
hook="${CMUX_POOL_DISK_FLOOR_HOOK:-/opt/cmux-disk-floor.sh}"
path="${CMUX_POOL_MAKE_ROOM_PATH:-${GITHUB_WORKSPACE:-$PWD}}"

gib() { awk -v b="$1" 'BEGIN {printf "%.1f", b / 1073741824}'; }
avail() { df -B1 --output=avail "$path" 2>/dev/null | tail -n 1 | tr -d ' '; }

if [ ! -x "$hook" ]; then
  echo "pool-make-room: no pool disk hook ($hook); nothing to do"
  exit 0
fi
free="$(avail)"
case "$free" in ''|*[!0-9]*) echo "pool-make-room: could not read free space at $path; building as is"; exit 0;; esac
if [ "$free" -ge "$need" ]; then
  echo "pool-make-room: $(gib "$free") GiB free, need $(gib "$need"); nothing to do"
  exit 0
fi
echo "pool-make-room: $(gib "$free") GiB free, under the step's need of $(gib "$need") GiB; pruning in line (up to ${wait_s} s)"
t0="$(date +%s)"
CMUX_DISK_FLOOR_CHILD=1 CMUX_DISK_FLOOR_BYTES="$need" CMUX_DISK_RESERVE_BYTES="$need" CMUX_DISK_JOB_BYTES="$need" \
  CMUX_DISK_FLOOR_LOCK_WAIT="$wait_s" bash "$(dirname "${BASH_SOURCE[0]}")/timeout.sh" --kill-after=5 "$wait_s" "$hook" room
after="$(avail)"
case "$after" in ''|*[!0-9]*) after=0;; esac
waited=$(( $(date +%s) - t0 ))
if [ "$after" -ge "$need" ]; then
  echo "pool-make-room: $(gib "$after") GiB free after ${waited} s (freed $(gib $((after - free))) GiB)"
else
  echo "::warning::pool-make-room: $(gib "$after") GiB free after ${waited} s, still under the step's need of $(gib "$need") GiB; building anyway"
fi
exit 0
