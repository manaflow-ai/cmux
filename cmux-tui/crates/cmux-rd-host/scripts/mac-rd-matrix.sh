#!/bin/zsh
# Runs the cmux.rd/1 click-latency bench on a host Mac for each host configuration, through a
# running mac-rig.sh (its FIFO and state directory). Writes ROOT/results/rd-<name>.json.
#   mac-rd-matrix.sh ROOT SAMPLES NAME=FLAGS...      e.g. native-60="--max-fps 60"
# FLAGS starting with "motion" also animate the whole display under the marker.
# Each NAME starts a fresh host with FLAGS (host-flags allowlist), reads the marker's origin
# and click point from its log, then measures SAMPLES clicks with the bench viewer
# (VideoToolbox decode) on the same Mac.
set -u
root=$1 samples=$2
shift 2
state=$root/state
mkdir -p "$root/results"
for spec in "$@"; do
  name=${spec%%=*} flags=${spec#*=} start=rd
  if [[ $flags == motion* ]]; then start=rd-motion flags=${flags#motion}; fi
  print -r -- "$flags" > "$state/host-flags"
  rm -f "$state/marker.log"
  echo $start > "$root/ctl"
  # The marker prints its geometry once it is on screen; the host is listening by then.
  for _ in {1..50}; do
    [[ -s "$state/marker.log" ]] && grep -q marker-origin "$state/marker.log" && break
    sleep 0.1 # bounded wait for the marker's first log line (5 s)
  done
  geometry=$(grep -m1 marker-origin "$state/marker.log")
  origin=${${geometry#marker-origin }%% *} at=${geometry##*click-at }
  for _ in {1..50}; do
    grep -q listening "$state/host.log" 2>/dev/null && break
    sleep 0.1 # bounded wait for the host's listening line (5 s)
  done
  addr=$(sed -n 's/.*listening on \([0-9.]*:[0-9]*\).*/\1/p' "$state/host.log")
  "$root/bin/cmux-rd-bench" bench --addr "$addr" --input click --at "$at" --marker-origin "$origin" \
    --samples "$samples" --user owner --token-fd 3 3< <(cat "$state/token") 2> "$root/results/rd-$name.err" \
    | tail -1 > "$root/results/rd-$name.json"
  echo "$name ($start$flags): $(wc -c < "$root/results/rd-$name.json") bytes"
done
rm -f "$state/host-flags"
echo stop > "$root/ctl"
