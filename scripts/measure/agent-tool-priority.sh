#!/usr/bin/env bash
# What an agent's tool call costs at each CPU class a harness can hand its children (`cpu_class.rs`),
# with the Mac busy, and what each class costs the app. macOS only; no build, no app.
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/agent-tool-priority.sh --ref SHA
#
# Classes: `normal` (nice 0), `nice11` (nice +11, the agent tier, `qos::AGENT_NICE`) and `bg`
# (`PRIO_DARWIN_BG`, `taskpolicy -b`: what a `background` harness's tool children inherit).
#
# 1. TOOL_CALL: the app busy (2 x cores of `yes` at nice 0, as a busy cmux and its renderers), one tool
#    call at each class: 200 `/usr/bin/true` spawns plus a fixed shell loop (a small build step's shape).
#    Median of ROUNDS wall seconds. An idle row runs the same call on an idle Mac.
# 2. APP_WAKE: the agent busy (2 x cores of `yes` at the class under test), the app's side: a nice-0
#    thread that sleeps 5 ms and wakes ROUNDS*40 times; p50/p95/max of its late wake in ms. What the
#    class buys the GUI (cmuxterm-hq#4947).
# Prints `TOOL_CALL class=... load=... median_s=...` and `APP_WAKE class=... p50_ms=... p95_ms=... max_ms=...`.
set -euo pipefail
rounds="${ROUNDS:-5}"
cores=$(sysctl -n hw.ncpu)
load=$((cores * 2))
pids=()
stop_load() {
  local p
  for p in "${pids[@]:-}"; do [ -n "$p" ] && { kill "$p"; wait "$p"; } 2>/dev/null || true; done
  pids=()
}
trap stop_load EXIT
start_load() { # $1: class of the load
  local i
  for ((i = 0; i < load; i++)); do
    case $1 in
      normal) perl -e 'alarm 600; exec "yes"' >/dev/null & ;;
      nice11) nice -n 11 perl -e 'alarm 600; exec "yes"' >/dev/null & ;;
      bg) taskpolicy -b perl -e 'alarm 600; exec "yes"' >/dev/null & ;;
    esac
    pids+=("$!")
  done
  sleep 1
}
tool_call='i=0; while [ $i -lt 200 ]; do /usr/bin/true; i=$((i+1)); done; j=0; while [ $j -lt 200000 ]; do j=$((j+1)); done'
run_at() { # $1: class; prints wall seconds of one tool call
  local t0 t1
  t0=$(perl -MTime::HiRes=time -e 'printf "%.4f", time')
  case $1 in
    normal) bash -c "$tool_call" ;;
    nice11) nice -n 11 bash -c "$tool_call" ;;
    bg) taskpolicy -b bash -c "$tool_call" ;;
  esac
  t1=$(perl -MTime::HiRes=time -e 'printf "%.4f", time')
  perl -e "printf '%.3f', $t1 - $t0"
}
median() { tr ' ' '\n' | grep -v '^$' | sort -g | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
tool_row() { # $1: class, $2: load label
  local r out=""
  for ((r = 0; r < rounds; r++)); do out="$out $(run_at "$1")"; done
  echo "TOOL_CALL class=$1 load=$2 cores=$cores median_s=$(echo "$out" | median) all_s=[${out# }]"
}
echo "host=$(hostname -s) cores=$cores load_procs=$load macos=$(sw_vers -productVersion) rounds=$rounds"
for c in normal nice11 bg; do tool_row "$c" idle; done
start_load normal
for c in normal nice11 bg; do tool_row "$c" app-busy; done
stop_load
for c in normal nice11 bg; do
  start_load "$c"
  perl -MTime::HiRes=time,sleep -e '
    my $n = $ARGV[0] * 40; my @late;
    for (1..$n) { my $t = time; sleep(0.005); push @late, (time - $t - 0.005) * 1000; }
    @late = sort { $a <=> $b } @late;
    printf "APP_WAKE class=%s p50_ms=%.2f p95_ms=%.2f max_ms=%.2f n=%d\n", $ARGV[1],
      $late[int($n*0.5)], $late[int($n*0.95)], $late[-1], $n;' "$rounds" "$c"
  stop_load
done
