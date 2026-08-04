#!/usr/bin/env bash
# Container entrypoint: enroll on first boot (one-use token from the
# environment), then run the headless cmux-tui session server and the iroh
# listener. Restarts reuse the persisted identity and credential, so the same
# (user, deviceId, tag) broker slot re-registers as a heartbeat.
set -euo pipefail

SESSION="${CMUX_TUI_SESSION:-main}"
TAG="${CMUX_TUI_IROH_TAG:?set CMUX_TUI_IROH_TAG (the device tag for the broker slot)}"
: "${CMUX_TUI_IROH_BROKER:?set CMUX_TUI_IROH_BROKER (broker base URL)}"

if [[ ! -f "$CMUX_TUI_STATE_DIR/device/iroh-credential.json" ]]; then
  echo "entrypoint: first boot, enrolling with the provisioning token"
  cmux-tui-iroh enroll --server --tag "$TAG"
else
  echo "entrypoint: identity present, skipping enrollment"
fi
# The one-use token is spent (or unnecessary); do not keep it in the process
# environment of long-running children.
unset CMUX_TUI_IROH_ENROLL_TOKEN

echo "entrypoint: starting headless cmux-tui session '$SESSION'"
cmux-tui --headless --session "$SESSION" &
MUX_PID=$!

# Wait for the session socket before starting the listener.
for _ in $(seq 1 50); do
  if [[ -S "${TMPDIR:-/tmp}/cmux-tui-$(id -u)/$SESSION.sock" ]]; then
    break
  fi
  sleep 0.2
done

echo "entrypoint: starting iroh listener"
cmux-tui-iroh listen --session "$SESSION" --tag "$TAG" &
LISTENER_PID=$!

trap 'kill "$LISTENER_PID" "$MUX_PID" 2>/dev/null || true' TERM INT
wait -n "$MUX_PID" "$LISTENER_PID"
echo "entrypoint: a component exited; stopping container" >&2
kill "$LISTENER_PID" "$MUX_PID" 2>/dev/null || true
exit 1
