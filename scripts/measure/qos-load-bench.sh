#!/usr/bin/env bash
# What agent load does to the app's foreground work, and what acpmux's agent QoS tier
# (cmux-tui/crates/acpmux/src/qos.rs) gives back (cmux#27587). Leo, 2026-10-29: "well somehow at
# "100% cpu" usage claude code desktop still seems fast / how does that work? how can cmux next
# also do that? let's do that".
#
# Probes at the app main thread's QoS (scripts/measure/qos-load-bench/probe.c): a 120 Hz frame
# (wake, 2 ms of work), a 4 KiB uncached read and a 4 KiB write + fsync every 50 ms, and a 64 KiB
# temp-file-and-rename save every 300 ms (Data.write(options: .atomic), the composer's draft
# throttle). Each round runs them idle, under agent-like load at the default priority (today), and
# under the same load in the agent tier (`taskpolicy -c utility -d utility`: the CPU clamp and
# disk policy acpmux applies to agent hosts and everything they start).
# Load: 4-thread CPU spinners to more than every core, 2 dd writers, 2 find metadata storms,
# 2 readers. Fleet Macs only, never an interactive machine:
#   scripts/measure/qos-load-bench.sh DIR [SECONDS=30] [ROUNDS=3] [SPIN_X=1] [TIERS=agent_tier]
# SPIN_X multiplies the spinner threads (1: ~1.2 per core; 8: ~8.4 per core, a load average near
# 8x cores, as air-blue and cosmic-gray report at their starved hangs: field-hang-seconds-tenth).
# TIERS is a comma- or space-separated list of load cells after load_default: agent_tier (`taskpolicy -c
# utility -d utility`), nice10 (`nice -n 10`, what reach and air-blue-build-guard give a build) and
# bg (`taskpolicy -b`, PRIO_DARWIN_BG: throttled CPU and disk).
# Everything it starts is its own job, stopped at the end of each cell; DIR is its scratch.
set -u
D=${1:?scratch directory}; S=${2:-30}; R=${3:-3}; X=${4:-1}; TIERS=${5:-agent_tier}; TIERS=${TIERS//,/ }
here="$(cd "$(dirname "$0")" && pwd)/qos-load-bench"
mkdir -p "$D" && D=$(cd "$D" && pwd -P) && cd "$D" || exit 1
cc -O2 -o probe "$here/probe.c" && cc -O2 -o spin "$here/spin.c" || exit 1
[ -f probe.dat ] || dd if=/dev/urandom of=probe.dat bs=1m count=512 2>/dev/null
mkdir -p loadtree
[ -f loadtree/done ] || { for i in $(seq 1 2000); do head -c 65536 /dev/urandom > "loadtree/f$i"; done; touch loadtree/done; }
# The writers' files live in a run folder this script makes, so cleanup removes only its own files.
RUN=$(mktemp -d "$D/run.XXXXXX") || exit 1
NCPU=$(sysctl -n hw.ncpu)
# Job control puts each load worker in its own process group, so stop() ends its dd, find, cat
# and shasum children too, not only the worker shells.
set -m
pgids=()
start() { "$@" & pgids+=("$!"); }
load() {
  for _ in $(seq 1 $((NCPU * X / 4 + 1))); do start $1 ./spin; done
  for _ in 1 2; do start $1 /bin/sh -c 'while :; do dd if=/dev/zero of="$1/w$$" bs=1m count=256 2>/dev/null; rm -f "$1/w$$"; done' sh "$RUN"; done
  for _ in 1 2; do start $1 /bin/sh -c 'while :; do find /System/Library /usr -type f -size +1k >/dev/null 2>&1; done'; done
  for _ in 1 2; do start $1 /bin/sh -c 'while :; do cat "$1"/loadtree/f* | shasum >/dev/null; done' sh "$D"; done
}
stop() {
  # bash 3.2 (macOS) with set -u treats an empty "${a[@]}" as unbound.
  for g in ${pgids[@]+"${pgids[@]}"}; do kill -TERM -- "-$g" 2>/dev/null; done
  wait 2>/dev/null; pgids=(); rm -f "$RUN"/w*; sleep 8
}
trap 'stop; rmdir "$RUN" 2>/dev/null' EXIT
echo "host $(sysctl -n hw.model) cores $NCPU seconds $S rounds $R spin_x $X tiers $TIERS"
for r in $(seq 1 "$R"); do
  echo "== round $r idle"; ./probe "$S" "$D" || exit 1
  load ""; sleep 5
  echo "== round $r load_default $(uptime | sed 's/.*averages: //')"; ./probe "$S" "$D" || exit 1; stop
  for t in $TIERS; do
    case $t in
      agent_tier) pre="taskpolicy -c utility -d utility" ;;
      nice10) pre="nice -n 10" ;;
      bg) pre="taskpolicy -b" ;;
      *) echo "unknown tier $t" >&2; exit 2 ;;
    esac
    load "$pre"; sleep 5
    echo "== round $r load_$t $(uptime | sed 's/.*averages: //')"; ./probe "$S" "$D" || exit 1; stop
  done
done
