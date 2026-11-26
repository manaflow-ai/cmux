#!/usr/bin/env bash
# Session budgets (cmux-tui/crates/acpmux/src/session_budget.rs, session_disk.rs) against synthetic runaways:
# each runaway runs in a throwaway user scope (budgetexp.slice) with the old limits (TasksMax alone, as agent
# host and bg_start task scopes had before) or the new budget, while a neighbor probe in its own scope times a
# 64 MB allocate+touch, a 2 ms CPU spin, a fork+exec and a 4 KB write+fsync every 100 ms (p50/p99 ms).
# Cases: idle, mem-old|mem-new|mem-nohigh (a 6 GB hog; new = MemoryMax=2G with MemoryHigh, nohigh = without),
# cpu-old|cpu-new (32 spinners), fork-old|fork-new (3000 forks; new = TasksMax=512), disk-old|disk-new (a dd
# writer, CAP_MB, default 2048; new emulates the disk watcher's rule at TICK seconds with FLOOR_GB).
# Run on a Linux host with a systemd user manager (a lane VM), light load, one case at a time:
#   scripts/measure/session-budget-runaway/run.sh cpu-old; scripts/measure/session-budget-runaway/run.sh cpu-new
# Writes only under OUT (default a new temporary directory) and deletes what it wrote.
set -u
D=$(cd "$(dirname "$0")" && pwd)
if [ -z "${OUT:-}" ]; then
  OUT=$(mktemp -d)
  # Only the directory this run made goes; a given OUT stays.
  trap 'rm -rf -- "$OUT"' EXIT
fi
export OUT
OLD="-p TasksMax=4096"
NEW="-p MemoryMax=2G -p MemoryHigh=1843M -p TasksMax=4096 -p CPUWeight=50 -p CPUQuota=1200% -p IOWeight=50 -p OOMPolicy=continue"
probe() { systemd-run --user --scope --quiet --slice=budgetexp.slice --unit=bexp-neighbor-$1 python3 -I "$D/neighbor.py" "$2" "$OUT/n-$1.json"; }
hog() { systemd-run --user --scope --quiet --slice=budgetexp.slice --unit=bexp-hog-$1 $2 "${@:3}"; }
pause() { read -r -t "$1" <> <(:) || true; }
case "${1:-}" in
idle) probe idle 15 ;;
mem-old|mem-new|mem-nohigh)
  P=$OLD; [ "$1" = mem-new ] && P=$NEW; [ "$1" = mem-nohigh ] && P="${NEW/-p MemoryHigh=1843M /}"
  probe "$1" 20 & np=$!
  pause 2; t0=$(date +%s.%N); hog "$1" "$P" timeout 25 python3 -I "$D/hogs.py" mem 6 8 2>&1 | tail -2
  echo "hog rc=${PIPESTATUS[0]} after $(echo "$(date +%s.%N) - $t0" | bc)s"
  wait $np ;;
cpu-old|cpu-new)
  P=$OLD; [ "$1" = cpu-new ] && P="$NEW"
  probe "$1" 20 & np=$!
  pause 2; hog "$1" "$P" python3 -I "$D/hogs.py" cpu 32 15; wait $np ;;
fork-old|fork-new)
  P="-p TasksMax=infinity"; [ "$1" = fork-new ] && P="-p TasksMax=512"
  probe "$1" 15 & np=$!
  pause 2; hog "$1" "$P" python3 -I "$D/hogs.py" fork 3000 6; wait $np ;;
disk-old|disk-new)
  M=old; [ "$1" = disk-new ] && M=watch
  probe "$1" 20 & np=$!
  pause 2; hog "$1" "$OLD" python3 -I "$D/disk.py" $M "${CAP_MB:-2048}" 512 "${FLOOR_GB:-10}" "${TICK:-15}"; wait $np ;;
*) echo "usage: $0 idle|mem-old|mem-new|mem-nohigh|cpu-old|cpu-new|fork-old|fork-new|disk-old|disk-new" >&2; exit 2 ;;
esac
[ -f "$OUT/n-$1.json" ] && echo "$1 neighbor: $(cat "$OUT/n-$1.json")" && rm -f "$OUT/n-$1.json"
