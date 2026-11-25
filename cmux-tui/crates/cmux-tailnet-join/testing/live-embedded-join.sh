#!/usr/bin/env bash
# Live join of acpmux's embedded tsnet node to a throwaway Headscale.
#
# Runs headscale-e2e.sh with KEEP=1 (headscale 0.27.1 plus a client node on a private docker
# network), then runs acpmux's ignored test `live_join_against_a_throwaway_headscale` in a
# container on that network with the harness's reusable key mounted read-only. While the node
# holds, the client's `tailscale status` must list it and `tailscale ping` must reach it.
# Everything carrying the run's label is removed at the end. Never a real tailnet; the host's
# tailscaled and network settings are untouched.
#
# Usage: live-embedded-join.sh ACPMUX_TEST_BINARY   Exit 0 when the node joined, was seen and pinged.
set -euo pipefail
BIN=$(readlink -f "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
if docker info >/dev/null 2>&1; then DOCKER=(docker); else DOCKER=(sudo -n docker); fi
d() { "${DOCKER[@]}" "$@"; }

OUT=$(mktemp)
KEEP=1 EPHEMERAL_WAIT_S=${EPHEMERAL_WAIT_S:-90} "$HERE/headscale-e2e.sh" >"$OUT" 2>&1 || true
RUN_ID=$(sed -n 's/.*KEEP=1: leaving run \([^ ]*\) .*/\1/p' "$OUT")
WORK=$(sed -n 's/.*work dir \(.*\)$/\1/p' "$OUT")
[[ -n $RUN_ID && -n $WORK ]] || { cat "$OUT"; echo "FAIL harness did not leave a run"; exit 1; }
LABEL="cmux.tailnet-e2e.run=$RUN_ID"
cleanup() {
  local ids
  ids=$(d ps -aq --filter "label=$LABEL"); [[ -n $ids ]] && d rm -fv $ids >/dev/null || true
  ids=$(d network ls -q --filter "label=$LABEL"); [[ -n $ids ]] && d network rm $ids >/dev/null || true
  rm -rf -- "$WORK" "$OUT"
}
trap cleanup EXIT
echo "harness: run $RUN_ID"; grep -E '^(PASS|FAIL)' "$OUT" || true

NODE="$RUN_ID-embedded"
d run -d --name "$NODE" --label "$LABEL" --network "$RUN_ID" \
  -e TS_DEBUG_USE_DERP_HTTP=1 -e CMUX_LIVE_KEY_FILE=/run/key -e CMUX_LIVE_SERVER=http://headscale:8080 \
  -e CMUX_LIVE_HOLD_S=60 -e CMUX_LIVE_TSNET_LOG=1 -e HOME=/tmp \
  -v "$BIN:/acpmux-tests:ro" -v "$WORK/keys/reusable:/run/key:ro" \
  ubuntu:24.04 /acpmux-tests --ignored --exact --nocapture \
  tailnet::embedded_join::tests::live_join_against_a_throwaway_headscale >/dev/null
for _ in $(seq 1 120); do
  d logs "$NODE" 2>&1 | grep -aq "LIVE READY" && break
  d ps -q --filter "name=$NODE" --filter status=running | grep -q . || break
  sleep 1
done
d logs "$NODE" 2>&1 | grep -a '^LIVE' || true
FAILS=0
CLIENT="$RUN_ID-client"
for _ in $(seq 1 30); do
  d exec "$CLIENT" tailscale status | grep cmux-embedded-live | grep -vq offline && break
  sleep 1
done
if d exec "$CLIENT" tailscale status | grep cmux-embedded-live | grep -v offline; then echo "PASS client status lists the embedded node"
else echo "FAIL client status"; d exec "$CLIENT" tailscale status || true; FAILS=1; fi
if d exec "$CLIENT" tailscale ping -c 10 cmux-embedded-live; then echo "PASS client pings the embedded node"
else echo "FAIL ping"; FAILS=1; fi
d wait "$NODE" >/dev/null || true
d logs "$NODE" 2>&1 | grep -aE '^LIVE left|test result' || true
d logs "$NODE" 2>&1 | grep -aq 'test result: ok. 1 passed' || { echo "FAIL the live test"; d logs "$NODE" 2>&1 | tail -30; FAILS=1; }
exit "$FAILS"
