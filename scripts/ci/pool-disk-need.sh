#!/usr/bin/env bash
# A cmux-tui package leg's disk need on a cmux-runner-pool VM, asked of the VM before the build starts.
#
# usage: scripts/ci/pool-disk-need.sh NEED_GIB
#
# Why: the pool admits a job on one job's need, 17 GiB (/opt/cmux-disk-floor.sh from cmuxterm-hq
# skills/infra/linux-runner-pool/pool.sh, admission.LinuxPoolJobNeedBytes), measured on swift checks and
# dev builds. A fat-LTO package leg is about twice that: every cargo group (scripts/ci/cargo-groups.sh)
# has its own target dir, and the aarch64-apple-darwin target alone is ~39 GB (parent lane's measurement,
# cmux#57987). On a 200 GB VM packed with 4 runners the leg ran the disk to zero mid-build and the runner
# died writing its own log: cmux-tui-artifacts run 45770293904, job 139741483015 (2026-11-26 06:45Z,
# cmux-runner-pool-w3c-0150-2, in "Build cmux-tui (Linux cross)"): "System.IO.IOException: No space left
# on device : '/home/runner2/actions-runner/_diag/Worker_...log'", with no under-the-floor warning from
# the job-started hook; job 139585424767 (11-26 00:07Z, runner3) and others the same.
#
# What: when the disk holds less than NEED_GIB, run the VM's own disk-floor hook in line with this leg's
# need (CMUX_DISK_JOB_BYTES, CMUX_DISK_FLOOR_BYTES): it prunes trash, logs, docker, every runner's sccache
# and idle runners' caches and checkouts, then this runner's caches, within CMUX_DISK_START_WAIT (180 s
# here), and never touches another runner's live job. Run it before anything restores into this runner's
# caches (the R2 registry restore). Still short: a ::warning:: with the numbers, and the hook has named
# what holds the disk in this log. Never fails the leg; off a pool VM (no hook) it only prints df.
# scripts/ci/tests/pool-disk-need.test.sh.
set -uo pipefail

need_gib="${1:-}"
[[ "$need_gib" =~ ^[0-9]+$ ]] || { echo "usage: $0 NEED_GIB" >&2; exit 2; }
hook="${CMUX_DISK_FLOOR_HOOK:-/opt/cmux-disk-floor.sh}"
disk="${CMUX_DISK_PATH:-/}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
need=$((need_gib << 30))

avail() { df -B1 --output=avail "$disk" 2>/dev/null | tail -n 1 | tr -d ' '; }
gib() { awk -v b="$1" 'BEGIN {printf "%.1f", b / 1073741824}'; }

free="$(avail)"
[[ "$free" =~ ^[0-9]+$ ]] || { echo "pool disk: df $disk unreadable; not checked"; exit 0; }
if [[ ! -x "$hook" ]]; then
  echo "pool disk: $(gib "$free") GiB free on $disk, this leg needs ${need_gib} GiB (no $hook: not a pool VM)"
  exit 0
fi
if ((free >= need)); then
  echo "pool disk: $(gib "$free") GiB free on $disk, this leg needs ${need_gib} GiB: ok"
  echo "pool disk: $(gib "$free") GiB free, need ${need_gib} GiB, ok" >> "$summary"
  exit 0
fi
echo "pool disk: $(gib "$free") GiB free on $disk, under this leg's ${need_gib} GiB; cleaning in line ($hook)"
t0=$SECONDS
wait_s="${CMUX_DISK_START_WAIT:-180}"
[[ "$wait_s" =~ ^[0-9]+$ ]] || wait_s=180
CMUX_DISK_JOB_BYTES="$need" CMUX_DISK_FLOOR_BYTES="$need" CMUX_DISK_START_WAIT="$wait_s" \
  CMUX_DISK_PATH="$disk" bash "$(dirname "${BASH_SOURCE[0]}")/timeout.sh" --kill-after=5 "$((wait_s + 30))" "$hook" started || true
after="$(avail)"
[[ "$after" =~ ^[0-9]+$ ]] || after=0
line="pool disk: $(gib "$free") -> $(gib "$after") GiB free in $((SECONDS - t0)) s, need ${need_gib} GiB"
if ((after >= need)); then
  echo "$line: ok"
  echo "$line, ok" >> "$summary"
else
  echo "::warning::cmux-runner-pool: $(hostname -s 2>/dev/null) $line; this leg may die \"No space left on device\" (scripts/ci/pool-disk-need.sh)"
  echo "$line, short" >> "$summary"
fi
exit 0
