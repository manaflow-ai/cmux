#!/usr/bin/env bash
# An agent's tool loop under duress, in the CPU class acpmux gave it before and after the dynamic
# class (cmux-tui/crates/acpmux/src/cpu_class/pressure.rs). Leo, 2026-11-25: "lucas ran into slow
# stuff on the desktop gui app with claude bc he was at relatively high cpu and agents' tool calls
# ran at background priority and stuff so it took like 87 minutes to do things... and then even when
# his cpu went down to 80% the background priority stayed".
#
# The tool loop: ROUNDS rounds of JOBS parallel jobs (work.c: fixed CPU work, then uncached reads of
# 200 64 KiB files), as a turn's build. Loads: other apps' busy threads at the default priority, one
# per core (`full`) and 80% of the cores (`eighty`), and none (`idle`). Arms:
#   background  PRIO_DARWIN_BG (`taskpolicy -b`), where the old default left every tool for good
#   dynamic     the agent tier's nice (+11) with normal I/O: where the dynamic class runs a turn the
#               person waits on at any load, and every turn once the controller reads the host clear
# Each load also runs probe.c, the controller's own reading, so the report says whether `dynamic`
# would demote there (`pressured_share`) or promote (`clear_share`).
# Fleet Macs only, never an interactive machine:
#   scripts/measure/agent-class-duress.sh OUT [ROUNDS=4] [JOBS=4] [CAP_S=900]
# Writes OUT/report.json. Everything it starts is its own job, ended at each cell's end.
set -u
OUT=${1:?output directory}; ROUNDS=${2:-4}; JOBS=${3:-4}; CAP=${4:-900}
ITERS=${AGENT_DURESS_ITERS:-600000000}
here="$(cd "$(dirname "$0")" && pwd)/agent-class-duress"
mkdir -p "$OUT" && OUT=$(cd "$OUT" && pwd -P) && cd "$OUT" || exit 1
cc -O2 -o work "$here/work.c" && cc -O2 -o spin "$here/spin.c" && cc -O2 -o probe "$here/probe.c" || exit 1
mkdir -p files
[ -f files/done ] || { for i in $(seq 1 200); do head -c 65536 /dev/urandom >"files/f$i"; done; touch files/done; }
NCPU=$(sysctl -n hw.ncpu)
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
set -m
spinners=()
load() {
  local n=$1
  for _ in $(seq 1 "$n"); do ./spin & spinners+=("$!"); done
}
unload() {
  for p in ${spinners[@]+"${spinners[@]}"}; do kill -KILL "$p" 2>/dev/null; done
  wait 2>/dev/null; spinners=(); sleep 3
}
trap unload EXIT
# One run of the tool loop in arm $1; prints its wall seconds, or CAP+ when it hit the cap.
loop() {
  local arm=$1 prefix start end
  case $arm in
    background) prefix="taskpolicy -b" ;;
    dynamic) prefix="nice -n 11" ;;
  esac
  start=$(now)
  $prefix /bin/sh -c '
    for r in $(seq 1 "$1"); do
      for j in $(seq 1 "$2"); do ./work "$3" files 200 & done
      wait
    done' sh "$ROUNDS" "$JOBS" "$ITERS" &
  local pid=$!
  ( sleep "$CAP"; kill -KILL -- "-$pid" 2>/dev/null ) &
  local dog=$!
  wait "$pid"; local rc=$?
  kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
  end=$(now)
  if [ "$rc" -ne 0 ]; then echo "cap"; else perl -e "printf '%.2f', $end - $start"; fi
}
rows=()
probes=()
echo "host $(sysctl -n hw.model) cores $NCPU rounds $ROUNDS jobs $JOBS iters $ITERS cap $CAP"
for spec in idle:0 eighty:$((NCPU * 8 / 10)) full:$((NCPU * 2)); do
  name=${spec%%:*}; n=${spec#*:}
  load "$n"; sleep 3
  readings=$(./probe 10 | tr '\n' ';')
  probes+=("{\"load\":\"$name\",\"spinners\":$n,\"readings\":\"$readings\"}")
  echo "== $name ($n spinners) probe: $readings"
  for arm in background dynamic; do
    wall=$(loop "$arm")
    echo "== $name $arm wall_s=$wall"
    rows+=("{\"load\":\"$name\",\"arm\":\"$arm\",\"wall_s\":\"$wall\"}")
  done
  unload
done
join() { local IFS=,; echo "$*"; }
cat >report.json <<JSON
{"host":"$(hostname -s)","model":"$(sysctl -n hw.model)","cores":$NCPU,"rounds":$ROUNDS,"jobs":$JOBS,"iters":$ITERS,"cap_s":$CAP,
 "cells":[$(join ${rows[@]+"${rows[@]}"})],
 "probes":[$(join ${probes[@]+"${probes[@]}"})]}
JSON
cat report.json
