#!/usr/bin/env bash
# Loopback functional bench on Linux with Xvfb: right token over UDP and the stream carrier,
# then refusals (no token, wrong token, no grant). Run from the repository root after
# `cargo build --release` in this crate. Env: WORKLOAD (marker|text), N1, N2, HOSTARGS.
set -u
cd "$(dirname "$0")/.."
B=$PWD/target/release/cmux-rd
for f in /tmp/rd-*.pid; do [ -f "$f" ] && kill "$(cat $f)" 2>/dev/null; rm -f "$f"; done
sleep 1 # let an earlier Xvfb release :97
command -v Xvfb >/dev/null || sudo apt-get install -y -qq xvfb >/dev/null 2>&1
TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
Xvfb :97 -screen 0 1920x1080x24 -nolisten tcp >/tmp/xvfb.log 2>&1 & echo $! > /tmp/rd-xvfb.pid
sleep 1
$B testapp --display :97 --workload "${WORKLOAD:-marker}" >/tmp/app.log 2>&1 & echo $! > /tmp/rd-app.pid
sleep 1
$B host --owner owner --display :97 --port 4103 ${HOSTARGS:---profile baseline} --token-fd 3 3< <(printf %s "$TOKEN") >/tmp/host.log 2>&1 & echo $! > /tmp/rd-host.pid
sleep 1
timeout 120 $B bench --addr 127.0.0.1:4103 --carrier udp --samples ${N1:-100} --user owner --token-fd 3 3< <(printf %s "$TOKEN") || echo FAIL1
timeout 120 $B bench --addr 127.0.0.1:4103 --carrier stream --samples ${N2:-50} --user owner --token-fd 3 3< <(printf %s "$TOKEN") || echo FAIL2
timeout 30 $B bench --addr 127.0.0.1:4103 --samples 5 --user owner || echo NO-TOKEN-REFUSED-EXPECTED
timeout 30 $B bench --addr 127.0.0.1:4103 --samples 5 --user owner --token-fd 3 3< <(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n') || echo WRONG-TOKEN-REFUSED-EXPECTED
timeout 30 $B bench --addr 127.0.0.1:4103 --samples 5 --user intruder --token-fd 3 3< <(printf %s "$TOKEN") || echo NOGRANT-REFUSED-EXPECTED
grep -v audit /tmp/host.log | tail -6
for f in /tmp/rd-*.pid; do kill "$(cat $f)" 2>/dev/null; rm -f "$f"; done
