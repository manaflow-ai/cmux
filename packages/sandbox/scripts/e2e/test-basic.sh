#!/usr/bin/env bash
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
CREATE_OUTPUT=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes create --name e2e --workspace /tmp/e2e)
echo "${CREATE_OUTPUT}"
# Extract ID from JSON output (assuming "id": "UUID")
ID=$(echo "${CREATE_OUTPUT}" | grep '"id":' | head -n1 | cut -d '"' -f 4)
echo "Created sandbox ID: ${ID}"

docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes list | tee /tmp/cmux-e2e-list.log

echo "Executing command in sandbox..."
# We expect "stdout": "hi\n" in the JSON response
EXEC_OUTPUT=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes exec "${ID}" "echo" "hi")
echo "${EXEC_OUTPUT}"

if echo "${EXEC_OUTPUT}" | grep -q "hi"; then
  echo "Exec test passed!"
else
  echo "Exec test failed!"
  exit 1
fi

echo "Testing default working directory..."
PWD_OUTPUT=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes exec "${ID}" "pwd")
echo "${PWD_OUTPUT}"
# We verify the JSON contains the correct stdout. 
# The output of pwd has a newline, so in JSON it becomes "/workspace\n"
if echo "${PWD_OUTPUT}" | grep -q '"stdout": "/workspace\\n"'; then
  echo "Default workdir test passed!"
else
  echo "Default workdir test failed! Expected /workspace"
  exit 1
fi

echo "Testing network connectivity..."
NET_OUTPUT=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes exec "${ID}" "curl" "-I" "https://example.com" || true)
echo "${NET_OUTPUT}"
if echo "${NET_OUTPUT}" | grep -q "HTTP/2 200"; then
  echo "Network test passed!"
else
  echo "Network test failed!"
  echo "${NET_OUTPUT}"
  exit 1
fi
