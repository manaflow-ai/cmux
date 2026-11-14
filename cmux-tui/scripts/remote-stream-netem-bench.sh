#!/usr/bin/env bash
# Run inside a private network namespace:
# sudo unshare -n bash remote-stream-netem-bench.sh BIN RTT_MS LOSS_PCT [RUNS] [SECONDS]
# Same workload and impairment as the connectivity map's desktop.sh: equal
# MTU, no segmentation offload, and every transport crosses kernel netem.
# A failed run fails the measurement instead of contributing an empty row.
set -euo pipefail

bin=$1 rtt=$2 loss=$3 runs=${4:-3} secs=${5:-8}
ip link set lo up
ip link set lo mtu 1500
ethtool -K lo gso off tso off gro off >/dev/null
half=$(python3 -c 'import sys; print(float(sys.argv[1]) / 2)' "$rtt")
tc qdisc add dev lo root netem delay "${half}ms" loss "${loss}%" limit 100000
for ((run=1; run<=runs; run++)); do
  for path in tcp wg-tcp rd-link; do
    line=$(timeout 120 "$bin" --path "$path" --seconds "$secs" --fps 60 \
      --frame-bytes 3500 --keyframe-bytes 200000 --bulk-bytes 4000000)
    printf '{"rtt_ms":%s,"loss_pct":%s,"run":%s,"path":"%s","result":%s}\n' \
      "$rtt" "$loss" "$run" "$path" "$line"
  done
done
