#!/usr/bin/env bash
# Measurement only: where an acpmux CLI call's time goes under CPU load. Not to be committed.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tui="$here/../cmux-tui"
work="$(mktemp -d)"
echo "host=$(hostname) cores=$(nproc) load='$(cut -d' ' -f1-3 /proc/loadavg)' free=$(df -h --output=avail "$work" | tail -1)"
which perf strace ltrace 2>&1 | sed 's/^/tool: /'
cd "$tui"
cargo build --release -p acpmux --bin acpmux 2>&1 | tail -2
tgt="$(cargo metadata --format-version 1 --no-deps 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')"
cp "$tgt/release/acpmux" "$work/acpmux"; B="$work/acpmux"
ls -la "$B"; size "$B" 2>/dev/null
readelf -S -W "$B" | grep -E 'init_array|rela.dyn|data.rel.ro' 
readelf -d "$B" | grep -E 'NEEDED|FLAGS|BIND_NOW'
export ACPMUX_HOME="$work/home" ACPMUX_SOCKET="$work/s.sock" ACPMUX_LOGIN_ENV=0 CLAUDE_CONFIG_DIR="$work/claude" ACPMUX_AGENT_LAUNCH=deny
mkdir -p "$ACPMUX_HOME" "$CLAUDE_CONFIG_DIR"
"$B" daemon run >"$work/daemon.log" 2>&1 &
dpid=$!
for i in $(seq 100); do [ -S "$ACPMUX_SOCKET" ] && break; sleep 0.1; done
"$B" --json ls | head -c 300; echo
echo "== idle perf stat"
for v in "--version" "--json ls"; do
  for t in "" 1; do
    echo "-- $v TOKIO_WORKER_THREADS=${t:-default}"
    env ${t:+TOKIO_WORKER_THREADS=$t} perf stat -r 30 -e task-clock,context-switches,cpu-migrations,page-faults "$B" $v 2>&1 >/dev/null | grep -E 'task-clock|context|migrations|faults|elapsed'
  done
done
echo "== idle strace -f -c (ls)"
strace -f -c -o "$work/c.txt" "$B" --json ls >/dev/null; head -40 "$work/c.txt"
echo "== idle strace -f -c (--version)"
strace -f -c -o "$work/c2.txt" "$B" --version >/dev/null; head -25 "$work/c2.txt"
echo "== execve/open/connect on ls path"
strace -f -e trace=execve,openat,connect,clone,clone3,statx,newfstatat -o "$work/o.txt" "$B" --json ls >/dev/null; grep -v ENOENT "$work/o.txt" | grep -vE 'clone|exited' | head -60; echo "clones: $(grep -cE 'clone3?\(' "$work/o.txt")"; echo "ENOENT opens: $(grep -c ENOENT "$work/o.txt")"
echo "== LD_DEBUG=statistics"
LD_DEBUG=statistics "$B" --version 2>&1 >/dev/null | head -20
echo "== perf record --version x200 (idle)"
perf record -q -g -o "$work/p.data" -- bash -c "for i in \$(seq 200); do '$B' --version >/dev/null; done" 2>/dev/null
perf report -i "$work/p.data" --no-children --comm acpmux --sort symbol --stdio 2>/dev/null | grep -E '^ +[0-9]' | head -40
echo "== perf record ls x200 (idle)"
perf record -q -g -o "$work/p2.data" -- bash -c "for i in \$(seq 200); do '$B' --json ls >/dev/null; done" 2>/dev/null
perf report -i "$work/p2.data" --no-children --comm acpmux --sort symbol --stdio 2>/dev/null | grep -E '^ +[0-9]' | head -40

timeit() { # label cmd... -> p50 p90 p99 max over N runs
  local label="$1"; shift; local n="${N:-60}"; local f="$work/t.$RANDOM"
  for i in $(seq "$n"); do s=$(date +%s%N); "$@" >/dev/null 2>&1; e=$(date +%s%N); echo $(( (e-s)/1000000 )); done | sort -n > "$f"
  echo "$label n=$n p50=$(sed -n "$((n/2))p" "$f") p90=$(sed -n "$((n*9/10))p" "$f") p99=$(sed -n "$((n*99/100))p" "$f") max=$(tail -1 "$f")"
}
pg=""
load_on() { setsid bash -c "for i in \$(seq $(( $(nproc) * 10 ))); do sh -c 'while :; do :; done' & done; wait" & pg=$!; sleep 5; }
load_off() { kill -- -"$pg" 2>/dev/null; sleep 2; }
echo "== under load ($(( $(nproc) * 10 )) busy loops)"
load_on
echo "load='$(cut -d' ' -f1-3 /proc/loadavg)'"
for round in 1 2; do
timeit true /bin/true
timeit version "$B" --version
TOKIO_WORKER_THREADS=1 timeit version-w1 env TOKIO_WORKER_THREADS=1 "$B" --version
timeit ls "$B" --json ls
timeit ls-w1 env TOKIO_WORKER_THREADS=1 "$B" --json ls
done
echo "-- perf stat under load"
for v in "--version" "--json ls"; do for t in "" 1; do
  echo "-- $v TOKIO_WORKER_THREADS=${t:-default}"
  env ${t:+TOKIO_WORKER_THREADS=$t} perf stat -r 20 -e task-clock,context-switches,cpu-migrations "$B" $v 2>&1 >/dev/null | grep -E 'task-clock|context|migrations|elapsed'
done; done
echo "-- strace -f -r -tt ls under load (3 runs, biggest gaps)"
for i in 1 2 3; do
  strace -f -tt -T -o "$work/r$i.txt" "$B" --json ls >/dev/null
  python3 - "$work/r$i.txt" <<'PY'
import sys,re
lines=open(sys.argv[1]).read().splitlines()
def t(l):
    m=re.match(r'\d+\s+(\d+):(\d+):([\d.]+)',l); return int(m[1])*3600+int(m[2])*60+float(m[3]) if m else None
ts=[(t(l),l) for l in lines if t(l) is not None]
print("total %.0f ms, %d lines, threads %d"%((ts[-1][0]-ts[0][0])*1000,len(ts),len({l.split()[0] for _,l in ts})))
gaps=sorted(((ts[i][0]-ts[i-1][0],i) for i in range(1,len(ts))),reverse=True)[:6]
for g,i in sorted(gaps,key=lambda x:x[1]):
    print("  gap %.0f ms before: %s"%(g*1000,ts[i][1][:150])); print("        after: %s"%ts[i-1][1][:150])
PY
done
load_off
kill "$dpid"; wait "$dpid" 2>/dev/null
rm -rf "$work"
