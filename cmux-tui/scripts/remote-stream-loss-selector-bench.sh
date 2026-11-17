#!/usr/bin/env bash
# The selector's loss rule against the connectivity map's lossy rows.
# Run inside a private network namespace, one row per call:
# sudo unshare -n bash remote-stream-loss-selector-bench.sh BIN RTT_MS LOSS_PCT [RUNS] [SECONDS]
# Same workload and impairment as remote-stream-netem-bench.sh (the map's
# desktop.sh): loopback MTU 1500, no segmentation offload, kernel netem
# delay RTT/2 and loss on every packet. Arms:
#   tcp           kernel TCP, the carrier relay's stand-in
#   wg-tcp        one cmux-wg TCP stream on direct UDP (the collapse)
#   race-off      wg-relay-race without the loss rule (direct UDP + relay)
#   race-on       wg-relay-race with it
set -euo pipefail

bin=$1 rtt=$2 loss=$3 runs=${4:-3} secs=${5:-8}
ip link set lo up
ip link set lo mtu 1500
ethtool -K lo gso off tso off gro off >/dev/null
half=$(python3 -c 'import sys; print(float(sys.argv[1]) / 2)' "$rtt")
tc qdisc add dev lo root netem delay "${half}ms" loss "${loss}%" limit 100000
for ((run=1; run<=runs; run++)); do
  for arm in tcp wg-tcp race-off race-on; do
    case $arm in
      race-off) flags=(--path wg-relay-race --loss-rule off) ;;
      race-on) flags=(--path wg-relay-race --loss-rule on) ;;
      *) flags=(--path "$arm") ;;
    esac
    line=$(timeout 120 "$bin" "${flags[@]}" --seconds "$secs" --fps 60 \
      --frame-bytes 3500 --keyframe-bytes 200000 --bulk-bytes 0) || line='{}'
    printf '{"rtt_ms":%s,"loss_pct":%s,"run":%s,"arm":"%s","result":%s}\n' \
      "$rtt" "$loss" "$run" "$arm" "$line"
  done
done
