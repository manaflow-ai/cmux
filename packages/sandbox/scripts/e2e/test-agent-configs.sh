#!/usr/bin/env bash
# E2E test for agent notification config files
# Verifies that Claude Code, Codex, and OpenCode config files are present in sandboxes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-cmux-sandbox-dev}"
PORT="${CMUX_SANDBOX_PORT:-46831}"
CONTAINER_NAME="${CONTAINER_NAME:-cmux-sandbox-e2e-$$}"
DOCKER_VOL="${DOCKER_VOL:-cmux-sandbox-e2e-docker-$$}"
SANDBOX_VOL="${SANDBOX_VOL:-cmux-sandbox-e2e-data-$$}"
KEEP_CONTAINER_ON_FAILURE="${KEEP_CONTAINER_ON_FAILURE:-}"

cleanup() {
  if [[ -n "${KEEP_CONTAINER_ON_FAILURE}" && "${KEEP_CONTAINER_ON_FAILURE}" != "0" ]]; then
    echo "Skipping cleanup because KEEP_CONTAINER_ON_FAILURE is set."
    return
  fi
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker volume rm -f "${DOCKER_VOL}" >/dev/null 2>&1 || true
  docker volume rm -f "${SANDBOX_VOL}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# If default port is busy, pick a free one.
if ! python3 - <<PY >/dev/null 2>&1
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
try:
    s.bind(("127.0.0.1", port))
    s.close()
    sys.exit(0)
except OSError:
    sys.exit(1)
PY
then
  PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("", 0))
print(s.getsockname()[1])
s.close()
PY
)"
  echo "Selected free port ${PORT}"
fi

echo "Building ${IMAGE_NAME} from ${ROOT_DIR}/packages/sandbox/Dockerfile"
docker build -t "${IMAGE_NAME}" -f "${ROOT_DIR}/packages/sandbox/Dockerfile" "${ROOT_DIR}"

echo "Starting systemd container ${CONTAINER_NAME} on port ${PORT}"
docker run --privileged -d \
  --name "${CONTAINER_NAME}" \
  --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --dns 1.1.1.1 --dns 8.8.8.8 \
  -e CMUX_SANDBOX_PORT="${PORT}" \
  -p "${PORT}:${PORT}" \
  -v "${DOCKER_VOL}":/var/lib/docker \
  -v "${SANDBOX_VOL}":/var/lib/cmux/sandboxes \
  --entrypoint /usr/local/bin/bootstrap-dind.sh \
  "${IMAGE_NAME}" \
  /usr/local/bin/cmux-sandboxd --bind 0.0.0.0 --port "${PORT}" --data-dir /var/lib/cmux/sandboxes

echo "Waiting for cmux-sandboxd health..."
healthy=""
for _ in $(seq 1 60); do
  if docker exec "${CONTAINER_NAME}" curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    healthy="yes"
    break
  fi
  sleep 1
done
if [[ -z "${healthy}" ]]; then
  echo "Health check failed; recent logs:"
  docker logs "${CONTAINER_NAME}" --tail 50 || true
  exit 1
fi

echo "Creating sandbox via cmux CLI..."
CREATE_OUTPUT=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes create --name agent-config-test --workspace /tmp/test)
echo "${CREATE_OUTPUT}"
ID=$(echo "${CREATE_OUTPUT}" | grep '"id":' | head -n1 | cut -d '"' -f 4)
echo "Created sandbox ID: ${ID}"

echo ""
echo "=== Testing Claude Code settings.json ==="
CLAUDE_OUTPUT=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes exec "${ID}" "cat" "/root/.claude/settings.json")
echo "${CLAUDE_OUTPUT}"
if echo "${CLAUDE_OUTPUT}" | grep -q "Notification"; then
  echo "Claude Code settings.json test PASSED!"
else
  echo "Claude Code settings.json test FAILED!"
  echo "Expected to find 'Notification' in settings.json"
  exit 1
fi

echo ""
echo "=== Testing Codex config.toml ==="
CODEX_OUTPUT=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes exec "${ID}" "cat" "/root/.codex/config.toml")
echo "${CODEX_OUTPUT}"
if echo "${CODEX_OUTPUT}" | grep -q "notify"; then
  echo "Codex config.toml test PASSED!"
else
  echo "Codex config.toml test FAILED!"
  echo "Expected to find 'notify' in config.toml"
  exit 1
fi

echo ""
echo "=== Testing OpenCode notification.js ==="
OPENCODE_OUTPUT=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes exec "${ID}" "cat" "/root/.config/opencode/plugin/notification.js")
echo "${OPENCODE_OUTPUT}"
if echo "${OPENCODE_OUTPUT}" | grep -q "NotificationPlugin"; then
  echo "OpenCode notification.js test PASSED!"
else
  echo "OpenCode notification.js test FAILED!"
  echo "Expected to find 'NotificationPlugin' in notification.js"
  exit 1
fi

echo ""
echo "=== All agent config tests PASSED! ==="
