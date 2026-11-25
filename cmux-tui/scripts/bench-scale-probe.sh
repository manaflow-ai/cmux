#!/usr/bin/env bash
# Probe a cmux-tui daemon: top threads by CPU over 5 s, then gdb stacks.
# usage: bench-scale-probe.sh <daemon pid> <out file>
pid=$1; out=$2
{
echo "== $(date -u +%T) pid $pid rss $(awk '/VmRSS/{print $2}' /proc/$pid/status) kB threads $(ls /proc/$pid/task | wc -l)"
declare -A t0
for t in /proc/$pid/task/*; do id=${t##*/}; set -- $(sed 's/.*) //' $t/stat 2>/dev/null); t0[$id]=$(( ${12:-0} + ${13:-0} )); done
sleep 5
for t in /proc/$pid/task/*; do id=${t##*/}; set -- $(sed 's/.*) //' $t/stat 2>/dev/null); d=$(( ${12:-0} + ${13:-0} - ${t0[$id]:-0} )); [ "$d" -gt 0 ] && echo "$d $id $(cat $t/comm)"; done | sort -rn | head -25
echo "== thread names (count)"
cat /proc/$pid/task/*/comm | sed 's/[0-9]\+/N/g' | sort | uniq -c | sort -rn | head -20
echo "== smaps top mappings by rss"
awk '/^[0-9a-f]+-/{name=$6} /^Rss:/{r[name]+=$2} END{for(n in r) print r[n], n}' /proc/$pid/smaps | sort -rn | head -8
echo "== gdb"
sudo timeout 120 gdb -batch -p $pid -ex "set pagination off" -ex "thread apply all bt 25" 2>/dev/null > $out.gdb
python3 - "$out.gdb" <<'PY'
import sys, re, collections
txt = open(sys.argv[1]).read()
threads = txt.split("\nThread ")
c = collections.Counter()
for th in threads[1:]:
    name = re.search(r'"([^"]*)"', th)
    frames = re.findall(r"#\d+\s+(?:0x[0-9a-f]+ in )?([^\s(]+)", th)
    key = (name.group(1) if name else "?") + " | " + " <- ".join(f[:60] for f in frames[:7])
    c[key] += 1
for k, n in c.most_common(25):
    print(n, k)
PY
} > $out 2>&1
