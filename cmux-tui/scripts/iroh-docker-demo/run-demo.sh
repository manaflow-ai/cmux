#!/usr/bin/env bash
# Stage-1 acceptance demo for the cmux-tui iroh transport.
#
# Proves, against a real broker and the managed relay fleet:
#   1. a cmux-tui session in a Linux Docker container behind NAT with ZERO
#      published ports is attachable from this Mac purely by EndpointID
#      resolved through the account device registry;
#   2. the session survives frontend detach/reattach;
#   3. a container restart re-registers the same (user, deviceId, tag) slot.
#
# Requirements:
#   - Docker running; image built:
#       docker build -f cmux-tui/scripts/iroh-docker-demo/Dockerfile \
#         -t cmux-tui-iroh-demo .            # from the cmux repo root
#   - host binaries: cargo build -p cmux-tui -p cmux-tui-iroh
#   - CMUX_TUI_IROH_BROKER: broker base URL whose deployment includes the
#     enrollment routes (PR 9515)
#   - an account to mint enrollment tokens with: mint-enrollment-token.mjs
#     signs in with CMUX_DEMO_ACCOUNT_FILE ({email,password} JSON) or the
#     team dogfood env, and prints one one-use token per call. Override the
#     whole mint with CMUX_DEMO_MINT_CMD.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUI_ROOT="$(cd "$HERE/../.." && pwd)"
BROKER="${CMUX_TUI_IROH_BROKER:?set CMUX_TUI_IROH_BROKER}"
# The container reaches a Mac-local dev broker via host.docker.internal.
CONTAINER_BROKER="${CMUX_DEMO_CONTAINER_BROKER:-${BROKER//localhost/host.docker.internal}}"
RUN_ID="$(date +%s)"
CONTAINER="cmux-tui-iroh-demo-$RUN_ID"
VOLUME="cmux-tui-iroh-demo-state-$RUN_ID"
SERVER_TAG="${CMUX_DEMO_SERVER_TAG:-boxd$((RUN_ID % 1000))}"
CLIENT_TAG="${CMUX_DEMO_CLIENT_TAG:-macd$((RUN_ID % 1000))}"
CLIENT_STATE="$(mktemp -d /tmp/cmux-tui-iroh-demo-client.XXXXXX)"
EVIDENCE="${CMUX_DEMO_EVIDENCE:-/tmp/cmux-tui-iroh-demo-$RUN_ID.log}"
KEEP="${CMUX_DEMO_KEEP:-0}"

log() { printf '\n=== %s\n' "$*" | tee -a "$EVIDENCE"; }
run() { "$@" 2>&1 | tee -a "$EVIDENCE"; }

cleanup() {
  local status=$?
  if [[ "$KEEP" != "1" ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
    rm -rf "$CLIENT_STATE"
  fi
  exit "$status"
}
trap cleanup EXIT

mint_token() {
  if [[ -n "${CMUX_DEMO_MINT_CMD:-}" ]]; then
    bash -c "$CMUX_DEMO_MINT_CMD"
    return
  fi
  CMUX_TUI_IROH_BROKER="$BROKER" node "$HERE/mint-enrollment-token.mjs"
}

log "stage-1 demo $RUN_ID (broker $BROKER, server tag $SERVER_TAG, client tag $CLIENT_TAG)"

log "1. minting two one-use enrollment tokens (server + client)"
SERVER_TOKEN="$(mint_token)"
CLIENT_TOKEN="$(mint_token)"
[[ -n "$SERVER_TOKEN" && -n "$CLIENT_TOKEN" ]]

log "2. starting the container: zero published ports, state volume $VOLUME"
run docker run -d --name "$CONTAINER" \
  -v "$VOLUME:/home/cmux/state" \
  -e CMUX_TUI_IROH_BROKER="$CONTAINER_BROKER" \
  -e CMUX_TUI_IROH_TAG="$SERVER_TAG" \
  -e CMUX_TUI_IROH_ENROLL_TOKEN="$SERVER_TOKEN" \
  ${CMUX_DEMO_CONTAINER_ENV:-} \
  cmux-tui-iroh-demo
log "container network facts (NAT bridge, no port mappings):"
run docker inspect "$CONTAINER" --format 'ports={{json .NetworkSettings.Ports}} ip={{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'

log "3. waiting for the listener to come online"
for _ in $(seq 1 60); do
  if docker logs "$CONTAINER" 2>&1 | grep -q "cmux-tui-iroh: listening"; then break; fi
  sleep 2
done
run docker logs "$CONTAINER"
docker logs "$CONTAINER" 2>&1 | grep -q "cmux-tui-iroh: listening"
SERVER_DEVICE_LINE="$(docker logs "$CONTAINER" 2>&1 | grep "enrolled device" | tail -1)"
log "server identity: $SERVER_DEVICE_LINE"

log "4. enrolling the Mac client identity"
CMUX_TUI_IROH_ENROLL_TOKEN="$CLIENT_TOKEN" run "$TUI_ROOT/target/debug/cmux-tui-iroh" enroll \
  --state "$CLIENT_STATE" --broker "$BROKER" --tag "$CLIENT_TAG"

log "5. seeding a marker in the container session (server-side truth)"
MARKER="IROH_DEMO_$RUN_ID"
run docker exec "$CONTAINER" cmux-tui workspace create --name "$MARKER"
run docker exec "$CONTAINER" cmux-tui workspace list

log "6. attach round 1 from this Mac by EndpointID via the broker registry"
"$HERE/attach-once.py" \
  --binary "$TUI_ROOT/target/debug/cmux-tui-iroh" \
  --state "$CLIENT_STATE" --broker "$BROKER" \
  --machine-tag "$SERVER_TAG" --expect-workspace "$MARKER" \
  --send-command "echo ATTACH1_${RUN_ID}_OK" 2>&1 | tee -a "$EVIDENCE"

log "7. detach happened at the end of round 1; attach round 2 (reattach) must see the same session"
"$HERE/attach-once.py" \
  --binary "$TUI_ROOT/target/debug/cmux-tui-iroh" \
  --state "$CLIENT_STATE" --broker "$BROKER" \
  --machine-tag "$SERVER_TAG" --expect-workspace "$MARKER" 2>&1 | tee -a "$EVIDENCE"

log "8. restarting the container; identity must re-register the same slot"
BINDING_BEFORE="$(docker exec "$CONTAINER" sh -c 'python3 -c "import json;print(json.load(open(\"/home/cmux/state/device/iroh-identity.json\"))[\"binding_id\"])" 2>/dev/null' || true)"
[[ -n "$BINDING_BEFORE" ]] || BINDING_BEFORE="$(docker exec "$CONTAINER" sh -c 'grep -o "\"binding_id\": *\"[^\"]*\"" /home/cmux/state/device/iroh-identity.json | head -1 | sed "s/.*: *\"//; s/\"//"')"
run docker restart "$CONTAINER"
for _ in $(seq 1 60); do
  if docker logs --since 1m "$CONTAINER" 2>&1 | grep -q "cmux-tui-iroh: listening"; then break; fi
  sleep 2
done
run docker logs --since 2m "$CONTAINER"
BINDING_AFTER="$(docker exec "$CONTAINER" sh -c 'grep -o "\"binding_id\": *\"[^\"]*\"" /home/cmux/state/device/iroh-identity.json | head -1 | sed "s/.*: *\"//; s/\"//"')"
log "binding before restart: $BINDING_BEFORE"
log "binding after restart:  $BINDING_AFTER"
[[ -n "$BINDING_BEFORE" && "$BINDING_BEFORE" == "$BINDING_AFTER" ]]

log "9. attach round 3 after restart (fresh mux session, same identity)"
"$HERE/attach-once.py" \
  --binary "$TUI_ROOT/target/debug/cmux-tui-iroh" \
  --state "$CLIENT_STATE" --broker "$BROKER" \
  --machine-tag "$SERVER_TAG" 2>&1 | tee -a "$EVIDENCE"

log "DEMO PASSED. Evidence: $EVIDENCE"
