#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-cmux-sandbox-dev}"
PORT="${CMUX_SANDBOX_PORT:-46832}" # Use a different port to avoid collision
CONTAINER_NAME="${CONTAINER_NAME:-cmux-sandbox-interactive-$RANDOM}"
DOCKER_VOL="${DOCKER_VOL:-cmux-sandbox-interactive-docker-$RANDOM}"
SANDBOX_VOL="${SANDBOX_VOL:-cmux-sandbox-interactive-data-$RANDOM}"
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

echo "Building ${IMAGE_NAME}..."
docker build -t "${IMAGE_NAME}" -f "${ROOT_DIR}/packages/sandbox/Dockerfile" "${ROOT_DIR}" >/dev/null

echo "Starting container ${CONTAINER_NAME}..."
docker run --privileged -d \
  --name "${CONTAINER_NAME}" \
  --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -e CMUX_SANDBOX_PORT="${PORT}" \
  -v "${DOCKER_VOL}":/var/lib/docker \
  -v "${SANDBOX_VOL}":/var/lib/cmux/sandboxes \
  --entrypoint /usr/local/bin/bootstrap-dind.sh \
  "${IMAGE_NAME}" \
  /usr/local/bin/cmux-sandboxd --bind 0.0.0.0 --port "${PORT}" --data-dir /var/lib/cmux/sandboxes

echo "Waiting for cmux-sandboxd health..."
healthy=""
for _ in $(seq 1 60); do
  if docker exec "${CONTAINER_NAME}" curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1;
 then
    healthy="yes"
    break
  fi
  sleep 1
done

if [[ -z "${healthy}" ]]; then
  echo "Health check failed"
  docker logs "${CONTAINER_NAME}"
  exit 1
fi

echo "Installing expect..."
docker exec "${CONTAINER_NAME}" apt-get update >/dev/null
docker exec "${CONTAINER_NAME}" apt-get install -y expect >/dev/null

echo "Running interactive shell test..."
# Copy the expect script to the container
docker cp "${ROOT_DIR}/packages/sandbox/tests/interactive_shell.exp" "${CONTAINER_NAME}:/tmp/interactive_shell.exp"

# Run expect
# Set TERM to xterm to make sure we get a PTY-like behavior if needed, but expect handles pty.
if docker exec -e CMUX_SANDBOX_URL="http://127.0.0.1:${PORT}" "${CONTAINER_NAME}" expect /tmp/interactive_shell.exp; then
  echo "Test PASSED"
else
  echo "Test FAILED"
  exit 1
fi