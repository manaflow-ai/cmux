#!/usr/bin/env bash
# Syscalls a tunnel datagram on cmux-wg bulk (cmuxterm-hq docs/design/wg-perf-layers.md, "Batching on bulk").
#
# Runs remote_stream_bench's bulk transfer through two cmux-wg peers on loopback UDP under `strace -c -f`, and a
# second time without strace for throughput. Datagrams are counted from the binary itself: pass
# DATAGRAMS=N (the wire datagrams of one run, e.g. the `sendto` count of a build that sends one per call) to get
# syscalls a datagram; without it the script prints syscalls a MB.
#
#   scripts/measure/wg-bulk-syscalls.sh BENCH_BINARY [wg-tcp|wg-mesh] [BULK_BYTES] [BENCH_ARGS...]
#   (wg-mesh needs `--paths lan:1`)
set -euo pipefail
bench=${1:?bench binary}
path=${2:-wg-tcp}
bytes=${3:-200000000}
args=(--path "$path" --seconds 1 --fps 1 --bulk-bytes "$bytes" "${@:4}")
out=$(mktemp -d)
strace -c -f -o "$out/strace" "$bench" "${args[@]}" >"$out/json" 2>"$out/stderr" || true
"$bench" "${args[@]}" >"$out/json2" 2>/dev/null || true
python3 -I - "$out" "$bytes" "${DATAGRAMS:-0}" <<'PY'
import json, re, sys
out, nbytes, datagrams = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
calls = {}
for line in open(f"{out}/strace"):
    f = line.split()
    if len(f) >= 5 and f[3].isdigit() and f[-1] != "total":
        calls[f[-1]] = int(f[3])
groups = {
    "send": ["sendto", "sendmsg", "sendmmsg"],
    "recv": ["recvfrom", "recvmsg", "recvmmsg"],
    "wakeups": ["epoll_wait", "epoll_pwait", "epoll_pwait2", "futex", "epoll_ctl", "write"],
}
total = sum(calls.values())
row = {k: sum(calls.get(n, 0) for n in v) for k, v in groups.items()}
row["all"] = total
row["calls"] = {n: calls[n] for n in sorted(calls, key=calls.get, reverse=True)[:10]}
row["mb"] = nbytes / 1e6
row["per_mb"] = {k: round(row[k] / row["mb"], 1) for k in ("send", "recv", "wakeups", "all")}
if datagrams:
    row["per_datagram"] = {k: round(row[k] / datagrams, 3) for k in ("send", "recv", "wakeups", "all")}
try:
    row["bulk_mbit_s"] = json.load(open(f"{out}/json2"))["bulk_mbit_s"]
    row["bulk_mbit_s_under_strace"] = json.load(open(f"{out}/json"))["bulk_mbit_s"]
except Exception as e:
    row["error"] = repr(e)
print(json.dumps(row))
PY
