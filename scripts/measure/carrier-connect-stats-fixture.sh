#!/usr/bin/env bash
# What it measures: `cmux carrier connect-stats` over a fixed connect.log of 8 cold connects
# (a paused machine's resume in parked_ms, then carrier.first_byte) and 8 warm reconnects, so a
# change to the summary's grouping or its first_byte (RFD 0223 row 2: start plus dial plus the
# machine's first answer) shows as a table diff. For a Mac's real numbers run
# `cmux carrier connect-stats` there (its own connect.log).
# Run: cmux-ci test --not-tests -- bash scripts/measure/carrier-connect-stats-fixture.sh
set -euo pipefail
cd cmux-tui
f=$(mktemp)
for i in 1 2 3 4 5 6 7 8; do
  echo "carrier.phases machine=vm_fx phase=connect carrier=relay:0 outcome=ok ticket_ms=4$i relay_ms=6$i parked_ms=$((1000+i*40)) handshake_ms=3$i mux_ms=5 lanes=1 ms=$((1180+i*45)) net=wifi region=us-west" >>$f
  echo "carrier.first_byte machine=vm_fx service=mux ms=$((1230+i*50))" >>$f
  echo "carrier.phases machine=vm_fx phase=reconnect carrier=relay:0 outcome=ok ticket_ms=0 relay_ms=5$i parked_ms=2 handshake_ms=3$i mux_ms=4 lanes=1 ms=$((95+i*6)) net=wifi region=us-west" >>$f
  echo "carrier.first_byte machine=vm_fx service=mux ms=$((120+i*7))" >>$f
done
echo STATS
cargo run -q -p cmux-tui --bin cmux-tui -- carrier connect-stats --log "$f"
