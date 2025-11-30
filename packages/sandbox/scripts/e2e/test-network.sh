#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-cmux-sandbox-dev}"
PORT="${CMUX_SANDBOX_PORT:-46833}" # Different port
CONTAINER_NAME="${CONTAINER_NAME:-cmux-sandbox-net-iso-$RANDOM}"
DOCKER_VOL="${DOCKER_VOL:-cmux-sandbox-net-iso-docker-$RANDOM}"
SANDBOX_VOL="${SANDBOX_VOL:-cmux-sandbox-net-iso-data-$RANDOM}"
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
  if docker exec "${CONTAINER_NAME}" curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
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

echo "Creating Sandbox A..."
CREATE_A=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes create --name sandbox-a)
ID_A=$(echo "${CREATE_A}" | grep '"id":' | head -n1 | cut -d '"' -f 4)
echo "Sandbox A ID: ${ID_A}"

echo "Starting HTTP Server in Sandbox A..."
# Use nohup and redirection to ensure it detaches and doesn't hold stdout open
docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes exec "${ID_A}" "sh" "-c" "nohup python3 -m http.server 8000 >/dev/null 2>&1 &"

echo "Checking server availability inside Sandbox A..."
# Loop a few times to let python start
success=""
for _ in $(seq 1 5); do
  OUTPUT=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes exec "${ID_A}" "curl" "-s" "http://127.0.0.1:8000")
  if echo "$OUTPUT" | grep -q '"exit_code": 0'; then
    success="yes"
    break
  fi
  sleep 1
done

if [[ -n "${success}" ]]; then
  echo "PASS: Sandbox A can curl itself."
else
  echo "FAIL: Sandbox A cannot curl itself."
  exit 1
fi

echo "Checking access from Root (Host)..."
if docker exec "${CONTAINER_NAME}" curl -s --connect-timeout 2 "http://127.0.0.1:8000"; then
  echo "FAIL: Root CAN curl Sandbox A on localhost (Isolation broken or test invalid)."
  exit 1
else
  echo "PASS: Root cannot curl Sandbox A on localhost."
fi

echo "Creating Sandbox B..."
CREATE_B=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes create --name sandbox-b)
ID_B=$(echo "${CREATE_B}" | grep '"id":' | head -n1 | cut -d '"' -f 4)
echo "Sandbox B ID: ${ID_B}"

echo "Checking access from Sandbox B (to localhost:8000)..."
# This verifies Sandbox B doesn't see Sandbox A's localhost
OUTPUT_B=$(docker exec "${CONTAINER_NAME}" cmux --base-url "http://127.0.0.1:${PORT}" sandboxes exec "${ID_B}" "curl" "-s" --connect-timeout 2 "http://127.0.0.1:8000")

# We expect curl to fail (non-zero exit code)
EXIT_CODE=$(echo "$OUTPUT_B" | grep '"exit_code":' | head -n1 | cut -d ':' -f 2 | tr -d ' ,')

if [[ "$EXIT_CODE" != "0" ]]; then
  echo "PASS: Sandbox B cannot curl localhost:8000 (Exit code: $EXIT_CODE)."
else
  echo "FAIL: Sandbox B CAN curl localhost:8000 (Exit code: 0)."
  exit 1
fi

echo "Network Isolation Test Suite PASSED."