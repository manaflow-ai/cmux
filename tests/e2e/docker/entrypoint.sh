#!/usr/bin/env bash
set -euo pipefail

/usr/sbin/sshd -D -e &
SSH_PID=$!

# Give sshd a moment to start
sleep 0.5

export CMUX_E2E_DOCKER=1

pytest -q /opt/cmuxterm/tests/e2e

kill "$SSH_PID"
wait "$SSH_PID" || true
