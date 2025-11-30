#!/usr/bin/env bash
set -euo pipefail

# Test Docker-in-Docker support inside sandboxes
# Verifies that the Docker socket is properly bind-mounted and Docker commands work.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-cmux-sandbox-dev}"
PORT="${CMUX_SANDBOX_PORT:-46834}"
CONTAINER_NAME="${CONTAINER_NAME:-cmux-sandbox-docker-e2e-$$}"
DOCKER_VOL="${DOCKER_VOL:-cmux-sandbox-docker-e2e-docker-$$}"
SANDBOX_VOL="${SANDBOX_VOL:-cmux-sandbox-docker-e2e-data-$$}"
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

echo "Waiting for Docker daemon to be ready..."
docker_ready=""
for _ in $(seq 1 30); do
  if docker exec "${CONTAINER_NAME}" docker info >/dev/null 2>&1; then
    docker_ready="yes"
    break
  fi
  sleep 1
done
if [[ -z "${docker_ready}" ]]; then
  echo "Docker daemon not ready; recent logs:"
  docker logs "${CONTAINER_NAME}" --tail 50 || true
  exit 1
fi
echo "Docker daemon is ready."

echo "Creating sandbox via cmux CLI..."
CREATE_OUTPUT=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes create --name docker-test --workspace /tmp/docker-test)
echo "${CREATE_OUTPUT}"
ID=$(echo "${CREATE_OUTPUT}" | grep '"id":' | head -n1 | cut -d '"' -f 4)
echo "Created sandbox ID: ${ID}"

echo "Testing Docker socket accessibility inside sandbox..."
DOCKER_INFO_OUTPUT=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes exec "${ID}" "docker" "info")
echo "${DOCKER_INFO_OUTPUT}"

if echo "${DOCKER_INFO_OUTPUT}" | grep -q '"exit_code": 0'; then
  echo "PASS: docker info succeeded inside sandbox"
else
  echo "FAIL: docker info failed inside sandbox"
  echo "${DOCKER_INFO_OUTPUT}"
  exit 1
fi

echo "Testing docker run hello-world inside sandbox..."
HELLO_OUTPUT=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes exec "${ID}" "docker" "run" "--rm" "hello-world")
echo "${HELLO_OUTPUT}"

if echo "${HELLO_OUTPUT}" | grep -q '"exit_code": 0'; then
  echo "PASS: docker run hello-world succeeded inside sandbox"
else
  echo "FAIL: docker run hello-world failed inside sandbox"
  echo "${HELLO_OUTPUT}"
  exit 1
fi

# Verify the output contains the expected hello-world message
if echo "${HELLO_OUTPUT}" | grep -q "Hello from Docker"; then
  echo "PASS: hello-world output contains expected message"
else
  echo "FAIL: hello-world output does not contain expected message"
  echo "${HELLO_OUTPUT}"
  exit 1
fi

echo "Testing docker build inside sandbox..."
# Create a simple Dockerfile in the sandbox
docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes exec "${ID}" "sh" "-c" "echo 'FROM alpine:latest' > /workspace/Dockerfile"

BUILD_OUTPUT=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes exec "${ID}" "docker" "build" "-t" "test-image" "/workspace")
echo "${BUILD_OUTPUT}"

if echo "${BUILD_OUTPUT}" | grep -q '"exit_code": 0'; then
  echo "PASS: docker build succeeded inside sandbox"
else
  echo "FAIL: docker build failed inside sandbox"
  echo "${BUILD_OUTPUT}"
  exit 1
fi

echo ""
echo "============================================"
echo "Docker-in-Docker e2e Test Suite PASSED!"
echo "============================================"
