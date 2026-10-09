#!/usr/bin/env bash
# Reproduces the D2 loopback bakeoff (d2-bakeoff.md). Unprivileged: no
# network shaping beyond the in-memory underlay. Runs one rig per process.
# Usage: plans/cmux-next/ios-next/bakeoff/run-local.sh [out-dir]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
out="${1:-$here/results}"
pkg="$root/Packages/Shared/CmuxLinkBench"
mkdir -p "$out"
swift build -j 4 -c release --package-path "$pkg" >/dev/null
bench="$pkg/.build/release/cmux-link-bench"

run() { local name="$1"; shift; echo "== $name" >&2; "$bench" "$@" --out "$out/$name.json" || echo "   ($name reported errors)" >&2; }

# Unshaped carriers on loopback (full size), three runs each (summarize.py takes medians).
for i in 1 2 3; do
  run "ref-r$i"        --rig ref
  run "v3-direct-r$i"  --rig v3
  run "v1-webrtc-r$i"  --rig v1
  run "v1-webrtc-bulk8k-r$i" --rig v1 --only rtt,rtt-bulk,bulk,raw --bulk-record 8192
  run "v2-webrtc-r$i"  --rig v2-webrtc
  run "v2-mem-r$i"     --rig v2-mem
done

# V2 on the in-memory underlay: RTT x loss matrix (quick size, bounded).
for rtt in 20 80 200; do
  for loss in 0 0.01 0.03; do
    run "v2-mem-rtt${rtt}-loss${loss}" --rig v2-mem --rtt-ms "$rtt" --loss "$loss" --quick
  done
done
