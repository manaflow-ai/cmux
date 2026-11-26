#!/usr/bin/env bash
# IO limits on a session scope against a 4 GB buffered writer (dd conv=fsync), while a neighbor probe in its own
# scope times a 64 MB allocate+touch, a 2 ms spin, a fork+exec and a 4 KB write+fsync every 100 ms (p50/p99 ms,
# neighbor.py). The writer's scope prints the io.max and io.weight it got: no file means systemd kept the
# property and the kernel ignores it (no `io` controller delegated to the user manager).
# Cases: io-none (no IO property), io-bw (IOWriteBandwidthMax=HOME 100M), io-weight (IOWeight=10).
# Compare a host before and after delegating io (`Delegate=cpu cpuset io memory pids` on user@.service, then
# `systemctl --user daemon-reexec`) and turning on iocost (`echo "MAJ:MIN enable=1" > /sys/fs/cgroup/io.cost.qos`).
#   scripts/measure/session-budget-runaway/io.sh io-weight
# Writes only under OUT (default a new temporary directory under HOME, the disk the sessions write) and
# deletes what it wrote.
set -u
D=$(cd "$(dirname "$0")" && pwd)
if [ -z "${OUT:-}" ]; then
  OUT=$(mktemp -d -p "$HOME")
  # Only the directory this run made goes; a given OUT stays.
  trap 'rm -rf -- "$OUT"' EXIT
fi
case "${1:-}" in
io-none) P=() ;;
io-bw) P=(-p "IOWriteBandwidthMax=$HOME 100M") ;;
io-weight) P=(-p IOWeight=10) ;;
*) echo "usage: $0 io-none|io-bw|io-weight" >&2; exit 2 ;;
esac
systemd-run --user --scope --quiet --slice=budgetexp.slice --unit="bexp-neighbor-$1" \
  python3 -I "$D/neighbor.py" 25 "$OUT/n-$1.json" & np=$!
read -r -t 2 <> <(:) || true
t0=$(date +%s.%N)
systemd-run --user --scope --quiet --slice=budgetexp.slice --unit="bexp-writer-$1" "${P[@]}" \
  sh -c 'cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup); echo "io.max: $(cat "$cg/io.max" 2>/dev/null || echo none)"
    echo "io.weight: $(cat "$cg/io.weight" 2>/dev/null || echo none)"
    dd if=/dev/zero of="$1/big.dat" bs=1M count=4096 conv=fsync status=none; rm -f -- "$1/big.dat"' sh "$OUT"
echo "writer took $(echo "$(date +%s.%N) - $t0" | bc)s"
wait $np
echo "$1 neighbor: $(cat "$OUT/n-$1.json")"
