#!/bin/sh
# Idle cost of the server user's service set over a window (default 120 s):
# CPU-s/min per cgroup (cpu.stat usage_usec), memory.current, PSS of the
# member processes, context switches of the long-running processes, and
# process creations per minute (/proc/stat "processes", whole VM).
# Run as root:  idle-cost.sh <uid> [seconds]
# The window itself uses only shell builtins plus one `sleep`.
set -eu
d=0
uid=${1:?uid}
win=${2:-120}
U=/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service
groups="$U $U/app.slice/cmux-server.service $U/app.slice/cmux-postgres.service $U/app.slice/cmux-server-inhibit.service /sys/fs/cgroup/system.slice/cmux-postgres.service"

usage() { # cgroup -> usage_usec
  while read -r k v; do
    if [ "$k" = usage_usec ]; then
      echo "$v"
      return
    fi
  done <"$1/cpu.stat"
}
forks() {
  while read -r k v; do
    if [ "$k" = processes ]; then
      echo "$v"
      return
    fi
  done </proc/stat
}
ctx() { # pid -> voluntary+nonvoluntary switches
  a=0
  while read -r k v; do
    case "$k" in voluntary_ctxt_switches: | nonvoluntary_ctxt_switches:) a=$((a + v)) ;; esac
  done <"/proc/$1/status"
  echo "$a"
}
pss_kb() { # cgroup -> summed Pss of its processes (kB)
  t=0
  while read -r p; do
    v=$(awk '/^Pss:/ {print $2}' "/proc/$p/smaps_rollup" 2>/dev/null || echo 0)
    t=$((t + ${v:-0}))
  done <"$1/cgroup.procs"
  echo "$t"
}

pids=$(cat "$U/app.slice/cmux-server.service/cgroup.procs" "$U/app.slice/cmux-postgres.service/cgroup.procs" 2>/dev/null)
echo "processes under watch:"
for p in $pids; do printf '  %s %s\n' "$p" "$(tr '\0' ' ' <"/proc/$p/cmdline" | cut -c1-90)"; done

i=0
for g in $groups; do
  i=$((i + 1))
  eval "u0_$i=\$(usage \"\$g\" 2>/dev/null || echo 0)"
done
for p in $pids; do eval "c0_$p=\$(ctx \"\$p\")"; done
f0=$(forks)
read -r up0 _ </proc/uptime
sleep "$win"
read -r up1 _ </proc/uptime
f1=$(forks)
i=0
for g in $groups; do
  i=$((i + 1))
  eval "u1_$i=\$(usage \"\$g\" 2>/dev/null || echo 0)"
done
for p in $pids; do eval "c1_$p=\$(ctx \"\$p\")"; done

secs=$(awk -v a="$up0" -v b="$up1" 'BEGIN {print b - a}')
echo "window_s=$secs"
i=0
for g in $groups; do
  i=$((i + 1))
  eval "d=\$((u1_$i - u0_$i))"
  mem=$(cat "$g/memory.current" 2>/dev/null || echo n/a)
  awk -v d="$d" -v s="$secs" -v n="$(case "$g" in /sys/fs/cgroup/system.slice/*) echo "system:${g##*/}" ;; *) echo "${g##*/}" ;; esac)" -v m="$mem" -v p="$(pss_kb "$g")" \
    'BEGIN {printf "  %-28s cpu=%.4f CPU-s/min (%.3f%% of a core)  memory.current=%s  pss=%.1f MiB\n", n, d / 1e6 / s * 60, d / 1e4 / s, (m == "n/a" ? m : sprintf("%.1f MiB", m / 1048576)), p / 1024}'
done
for p in $pids; do
  eval "d=\$((c1_$p - c0_$p))"
  awk -v d="$d" -v s="$secs" -v p="$p" -v c="$(tr '\0' ' ' <"/proc/$p/cmdline" | cut -c1-60)" \
    'BEGIN {printf "  ctx switches/s %-8s %.2f  %s\n", p, d / s, c}'
done
awk -v d="$((f1 - f0))" -v s="$secs" 'BEGIN {printf "process creations (whole VM): %d in %.0f s = %.1f per minute (includes this script'"'"'s sleep)\n", d, s, d / s * 60}'
