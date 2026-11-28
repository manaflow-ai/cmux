#!/usr/bin/env bash
# Measures: process start to exit of `acpmux --version` (the cost every short-lived acpmux, each
# hook and CLI call, pays before its own work) for two binaries, alternated: Callgrind total
# instructions, warm wall p50/p10/p90, cold-cache wall (page cache dropped before each run, needs
# sudo) and wall under 2x-CPU busy-loop load. Also prints each binary's size and relocation sections.
# Run: cmux-ci test --route actions --not-tests -- bash scripts/measure/acpmux-cli-startup.sh BEFORE AFTER
# (build the two binaries first in the same job, e.g. one per side of a patch).
set -u
before=$1 after=$2
for v in "$before" "$after"; do [ -x "$v" ] || { echo "no binary at $v" >&2; exit 2; }; done
H=$(mktemp -d); trap 'rm -rf "$H"' EXIT
export HOME=$H XDG_CONFIG_HOME=$H/c XDG_STATE_HOME=$H/s XDG_DATA_HOME=$H/d XDG_RUNTIME_DIR=$H ACPMUX_SOCKET=$H/no.sock
for v in "$before" "$after"; do
  echo "== $v size $(stat -c %s "$v")"
  readelf -S -W "$v" | grep -E "rela.dyn|relr.dyn"
  "$v" --version || echo "RUN FAILED $v"
  if command -v valgrind >/dev/null; then
    valgrind --tool=callgrind --callgrind-out-file="$H/cg" "$v" --version >/dev/null 2>&1
    echo "IR $v $(callgrind_annotate "$H/cg" 2>/dev/null | grep 'PROGRAM TOTALS')"
  fi
done
wall() {
  python3 - "$before" "$after" "$@" <<'PY'
import statistics, subprocess, sys, time
bins = sys.argv[1:3]; n = int(sys.argv[3]); mode = sys.argv[4]
res = {b: [] for b in bins}
for i in range(n):
    for b in (bins if i % 2 == 0 else bins[::-1]):
        if mode == "cold":
            subprocess.run(["sudo", "sh", "-c", "sync; echo 3 > /proc/sys/vm/drop_caches"])
        t = time.perf_counter()
        subprocess.run([b, "--version"], stdout=subprocess.DEVNULL)
        res[b].append((time.perf_counter() - t) * 1000)
for b in bins:
    s = sorted(res[b])
    print(mode, b, "n=%d p50=%.3f ms p10=%.3f p90=%.3f" % (n, statistics.median(s), s[n // 10], s[n * 9 // 10]))
PY
}
wall 400 warm
sudo -n true 2>/dev/null && wall 30 cold
pids=()
for _ in $(seq $(( $(nproc) * 2 ))); do timeout 300 sh -c 'while :; do :; done' & pids+=($!); done
sleep 1
echo "load: $(cat /proc/loadavg)"
wall 200 loaded
kill ${pids[@]+"${pids[@]}"} 2>/dev/null
