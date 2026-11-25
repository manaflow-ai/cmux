#!/usr/bin/env bash
# Interactive-speed probe (RFD 0072 piece 1): is this computer under load, or slowing interactive work?
#   scripts/measure/interactive-lateness.sh SECONDS LABEL
# Runs SECONDS (default 6) and prints ONE JSON line: how late a thread that sleeps 10 ms wakes
# (p50/p95/p99/max ms, share over 5 ms and over 16 ms, wake count), CPU busy % over the run, memory
# pressure, swap used/total and swap-out growth, thermal state, HID idle seconds (macOS), load 1/5/15,
# logical CPUs and performance levels. Read-only: no app, no defaults, no osascript. macOS (bash 3.2,
# BSD tools) and Linux. Needs python3. Missing readings are null.
# Timer: a python3 -I helper sleeps 10 ms in a loop for the whole run; lateness is the wake time past
# the 10 ms asked for, the only sleep here besides the run itself.
set -u
secs=${1:-6}
label=${2:-probe}
case "$secs" in ''|*[!0-9]*) echo "usage: $0 SECONDS LABEL" >&2; exit 2;; esac
[ "$secs" -ge 1 ] || { echo "SECONDS must be at least 1" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lateness.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
os=$(uname -s)
kv="$tmp/kv"
: >"$kv"
put() { printf '%s=%s\n' "$1" "$2" >>"$kv"; }

# Timer helper: writes its result to $1 after $2 seconds.
timer_py='
import sys, time, json
out, secs = sys.argv[1], float(sys.argv[2])
ask = 0.010
late = []
end = time.monotonic() + secs
while True:
    t0 = time.monotonic()
    if t0 >= end:
        break
    time.sleep(ask)
    late.append((time.monotonic() - t0 - ask) * 1000.0)
late.sort()
n = len(late)
def pct(p):
    return round(late[min(n - 1, int(p * n))], 3) if n else None
r = {"wakes": n, "p50_ms": pct(0.50), "p95_ms": pct(0.95), "p99_ms": pct(0.99),
     "max_ms": round(late[-1], 3) if n else None,
     "share_over_5ms": round(sum(1 for x in late if x > 5) / n, 5) if n else None,
     "share_over_16ms": round(sum(1 for x in late if x > 16) / n, 5) if n else None}
json.dump(r, open(out, "w"))
'

# Before readings.
swapout_now() {
  if [ "$os" = Darwin ]; then
    vm_stat 2>/dev/null | awk -F: '/Swapouts/ {gsub(/[ .]/,"",$2); print $2}'
  else
    awk '/^pswpout/ {print $2}' /proc/vmstat 2>/dev/null
  fi
}
cpu_sample() { awk '/^cpu / {idle=$5+$6; t=0; for(i=2;i<=NF;i++) t+=$i; print idle, t}' /proc/stat; }
swap0=$(swapout_now)
[ "$os" = Linux ] && cpu0=$(cpu_sample)

python3 -I -c "$timer_py" "$tmp/timer.json" "$secs" &
timer_pid=$!
if [ "$os" = Darwin ]; then
  # Second sample of top covers the run (the first is since boot).
  top -l 2 -s "$secs" -n 0 2>/dev/null | awk '/^CPU usage/ {line=$0} END {print line}' >"$tmp/top" &
  top_pid=$!
fi
wait "$timer_pid"
[ "$os" = Darwin ] && wait "$top_pid"

swap1=$(swapout_now)
if [ "$os" = Linux ]; then
  cpu1=$(cpu_sample)
  set -- $cpu0 $cpu1
  dt=$(( $4 - $2 )); di=$(( $3 - $1 ))
  [ "$dt" -gt 0 ] && put cpu_busy_pct "$(awk -v t="$dt" -v i="$di" 'BEGIN{printf "%.1f", 100*(t-i)/t}')"
else
  # "CPU usage: 8.7% user, 5.1% sys, 86.2% idle"
  idle=$(sed -n 's/.* \([0-9.]*\)% idle.*/\1/p' "$tmp/top")
  [ -n "$idle" ] && put cpu_busy_pct "$(awk -v i="$idle" 'BEGIN{printf "%.1f", 100-i}')"
fi
[ -n "$swap0" ] && [ -n "$swap1" ] && put swapout_growth_pages "$((swap1 - swap0))"

if [ "$os" = Darwin ]; then
  put mem_pressure_level "$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)"
  put mem_free_pct "$(sysctl -n kern.memorystatus_level 2>/dev/null)"
  # vm.swapusage: total = 24.00G  used = 22.90G  free = 1.10G  (encrypted)
  sw=$(sysctl -n vm.swapusage 2>/dev/null)
  put swap_total_mb "$(printf '%s' "$sw" | awk '{v=$3; u=substr(v,length(v)); n=v+0; if(u=="G")n*=1024; else if(u=="K")n/=1024; printf "%.0f", n}')"
  put swap_used_mb "$(printf '%s' "$sw" | awk '{v=$6; u=substr(v,length(v)); n=v+0; if(u=="G")n*=1024; else if(u=="K")n/=1024; printf "%.0f", n}')"
  put thermal "$(pmset -g therm 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/ $//')"
  hid=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print $NF; exit}')
  [ -n "$hid" ] && put hid_idle_s "$(awk -v n="$hid" 'BEGIN{printf "%.1f", n/1e9}')"
  put load "$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1, $2, $3}')"
  put cpus "$(sysctl -n hw.logicalcpu 2>/dev/null)"
  put perflevels "$(for i in 0 1 2 3; do n=$(sysctl -n hw.perflevel$i.name 2>/dev/null) || break; p=$(sysctl -n hw.perflevel$i.physicalcpu 2>/dev/null); echo "$n:$p"; done | tr '\n' ',' | sed 's/,$//')"
else
  put mem_pressure_psi_some_avg10 "$(awk '/^some/ {for(i=1;i<=NF;i++) if($i ~ /^avg10=/) {sub("avg10=","",$i); print $i}}' /proc/pressure/memory 2>/dev/null)"
  put mem_free_pct "$(awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} END {if(t>0) printf "%.0f", 100*a/t}' /proc/meminfo 2>/dev/null)"
  put swap_total_mb "$(awk '/^SwapTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)"
  put swap_used_mb "$(awk '/^SwapTotal/ {t=$2} /^SwapFree/ {f=$2} END {printf "%.0f", (t-f)/1024}' /proc/meminfo 2>/dev/null)"
  th=$(for z in /sys/class/thermal/thermal_zone*/temp; do [ -r "$z" ] && cat "$z" 2>/dev/null; done | sort -n | tail -1)
  [ -n "$th" ] && put thermal "max_zone_c=$((th / 1000))"
  put load "$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null)"
  put cpus "$(getconf _NPROCESSORS_ONLN 2>/dev/null)"
fi

python3 -I -c '
import sys, json
timer = json.load(open(sys.argv[1]))
kv = {}
for line in open(sys.argv[2]):
    k, _, v = line.rstrip("\n").partition("=")
    kv[k] = v
def num(k):
    try:
        f = float(kv[k]); return int(f) if f == int(f) and "." not in kv[k] else f
    except (KeyError, ValueError):
        return None
def txt(k):
    return kv.get(k) or None
out = {"label": sys.argv[3], "os": sys.argv[4], "seconds": int(sys.argv[5]), "lateness": timer}
for k in ("cpu_busy_pct", "mem_pressure_level", "mem_pressure_psi_some_avg10", "mem_free_pct",
          "swap_used_mb", "swap_total_mb", "swapout_growth_pages", "hid_idle_s", "cpus"):
    out[k] = num(k)
out["thermal"] = txt("thermal")
out["perflevels"] = txt("perflevels")
l = (kv.get("load") or "").split()
out["load"] = [float(x) for x in l] if len(l) == 3 else None
print(json.dumps(out, separators=(",", ":")))
' "$tmp/timer.json" "$kv" "$label" "$os" "$secs"
