#!/usr/bin/env bash
# The selector's loss rule and the tunnel MTU against the connectivity map's
# lossy rows. Run inside a private network namespace, one row per call:
# sudo unshare -n bash remote-stream-loss-selector-bench.sh BIN RTT_MS LOSS_PCT [RUNS] [SECONDS]
# Same workload and impairment as remote-stream-netem-bench.sh (the map's
# desktop.sh): loopback MTU 1500, no segmentation offload, kernel netem
# delay RTT/2 and loss on every packet. Arms:
#   tcp           kernel TCP, the carrier relay's stand-in
#   wg-tcp        one cmux-wg TCP stream on direct UDP, tunnel MTU 1200 (MSS 1160)
#   wg-tcp-1420   the same at WireGuard's default MTU 1420 (MSS 1380)
#   race-off      wg-relay-race without the loss rule (direct UDP + relay)
#   race-on       wg-relay-race with it
# Each line carries the kernel's counter deltas over the arm (/proc/net/snmp):
# fragments made or reassembled, UDP buffer drops, TCP resends.
set -euo pipefail

bin=$1 rtt=$2 loss=$3 runs=${4:-3} secs=${5:-8}
ip link set lo up
ip link set lo mtu 1500
ethtool -K lo gso off tso off gro off >/dev/null 2>&1 || true
half=$(python3 -c 'import sys; print(float(sys.argv[1]) / 2)' "$rtt")
tc qdisc add dev lo root netem delay "${half}ms" loss "${loss}%" limit 100000

# One "Proto.Field value" line per counter.
snap() {
  awk '/^(Ip|Udp|Tcp):/ {
    if (!($1 in seen)) { seen[$1] = 1; for (i = 2; i <= NF; i++) name[i] = $i; next }
    for (i = 2; i <= NF; i++) print substr($1, 1, length($1) - 1) "." name[i], $i
  }' /proc/net/snmp
}
# The counters that tell fragmentation, buffer drops and resends apart.
delta() {
  awk 'NR == FNR { before[$1] = $2; next }
    $1 ~ /^(Ip\.(FragCreates|FragFails|ReasmReqds|ReasmFails|InDiscards|OutDiscards)|Udp\.(InDatagrams|RcvbufErrors|SndbufErrors|InErrors)|Tcp\.(OutSegs|RetransSegs))$/ {
      printf "%s%s=%d", sep, $1, $2 - before[$1]; sep = ","
    }' "$1" "$2"
}

for ((run=1; run<=runs; run++)); do
  for arm in tcp wg-tcp wg-tcp-1420 race-off race-on; do
    case $arm in
      wg-tcp-1420) flags=(--path wg-tcp --mtu 1420) ;;
      race-off) flags=(--path wg-relay-race --loss-rule off) ;;
      race-on) flags=(--path wg-relay-race --loss-rule on) ;;
      *) flags=(--path "$arm") ;;
    esac
    snap > /tmp/snmp.before
    line=$(timeout 120 "$bin" "${flags[@]}" --seconds "$secs" --fps 60 \
      --frame-bytes 3500 --keyframe-bytes 200000 --bulk-bytes 0) || line='{}'
    snap > /tmp/snmp.after
    counters=$(delta /tmp/snmp.before /tmp/snmp.after)
    printf '{"rtt_ms":%s,"loss_pct":%s,"run":%s,"arm":"%s","counters":"%s","result":%s}\n' \
      "$rtt" "$loss" "$run" "$arm" "$counters" "$line"
  done
done
