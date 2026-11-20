#!/usr/bin/env bash
# launch-ready-preflight.sh THRESHOLD: before launch-ready.sh's first launch, is a system indexer busy on this Mac?
# A step ran ~25 min while mediaanalysisd sat at ~120 % CPU and Spotlight's mds at ~39 %: every launch saw a 1-minute
# load of 10 to 17 and the step was void. This check costs ~10 s instead.
# CPU is read with `top -l 3 -s 5`: top's first sample has no interval behind it (every process reads 0), so the
# second and third (5 s each) are averaged. `ps` %cpu on macOS is a decaying average over about a minute, which can
# still show a process that just stopped or miss one that just started. Each name's processes are summed per sample
# (mdworker_shared runs many at once). Above THRESHOLD % for any name in INDEXERS:
#   LR-HOT-HOST name=pct,... (threshold N%) host_noisy=0|1 load_1m=L
#   LR-HOT-HOST top5 name=pct,...
# and exit 1. Otherwise `LR-PREFLIGHT ok host_noisy=0 load_1m=L top=name=pct,...` (the top 3) and exit 0. CPU it cannot read
# prints `LR-PREFLIGHT unread` and passes: the check never fails a run on its own tooling. Kills and renices nothing.
# cmux-ci marks a step that starts on a loaded host with CMUX_CI_HOST_NOISY=1: every line carries host_noisy=0|1, and
# host_noisy=1 fails the check too (LR-HOT-HOST host_noisy=1 ...), whatever top read.
# Tested by tests/launch-ready-preflight.test.sh (it stubs top and sysctl on PATH).
set -uo pipefail

# System indexers and background analysis that macOS starts on its own. Add a name here to make it count.
INDEXERS=(mediaanalysisd mds mds_stores mdworker mdworker_shared photoanalysisd corespotlightd backupd softwareupdated
  suggestd)

threshold="${1:-30}"
[[ "$threshold" =~ ^[0-9]+$ && "$threshold" -ge 1 ]] || { echo "launch-ready-preflight: threshold takes a whole percent >= 1" >&2; exit 2; }

noisy=0; [[ "${CMUX_CI_HOST_NOISY:-}" == 1 ]] && noisy=1
load="$(sysctl -n vm.loadavg 2>/dev/null | awk '{ print $2 }')"
samples="$(top -l 3 -s 5 -n 20 -o cpu -stats pid,cpu,command 2>/dev/null)"

# One line per name, highest first: "name pct", pct the mean over the samples after the first of the summed CPU.
table="$(printf '%s\n' "$samples" | awk '
  /^Processes:/ { sample++; rows = 0; next }
  /^ *PID +%CPU/ { rows = 1; next }
  rows && sample > 1 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.]+$/ {
    pct = $2 + 0; $1 = ""; $2 = ""; sub(/^ +/, ""); gsub(/ /, "_"); name = $0
    sum[name] += pct; used = sample
  }
  END {
    n = used - 1
    if (n < 1) exit
    for (name in sum) printf "%s %.1f\n", name, sum[name] / n
  }' | sort -k2,2 -rn)"

if [[ -z "$table" ]]; then
  if [[ "$noisy" == 1 ]]; then
    echo "LR-HOT-HOST host_noisy=1 (cmux-ci marked this host loaded; top printed no samples) load_1m=${load:-none}"; exit 1
  fi
  echo "LR-PREFLIGHT unread host_noisy=0 load_1m=${load:-none} (top printed no samples; not checked)"
  exit 0
fi

join_top() { head -"$1" <<<"$table" | awk '{ printf "%s%s=%s", (NR > 1 ? "," : ""), $1, $2 }'; }

hot="$(awk -v list=" ${INDEXERS[*]} " -v limit="$threshold" '
  index(list, " " $1 " ") && $2 + 0 > limit + 0 { printf "%s%s=%s", (n++ ? "," : ""), $1, $2 }' <<<"$table")"

if [[ -n "$hot" || "$noisy" == 1 ]]; then
  echo "LR-HOT-HOST ${hot:-none} (threshold ${threshold}%) host_noisy=$noisy load_1m=${load:-none}"
  echo "LR-HOT-HOST top5 $(join_top 5)"
  exit 1
fi
echo "LR-PREFLIGHT ok host_noisy=0 load_1m=${load:-none} top=$(join_top 3)"
