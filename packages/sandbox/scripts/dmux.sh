#!/usr/bin/env bash
set -euo pipefail

# dmux.sh - Development/debug version of the sandbox server
# Uses different ports/containers than cmux to avoid conflicts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-dmux-sandbox-dev}"
PORT="${DMUX_SANDBOX_PORT:-46833}"
CONTAINER_NAME="${CONTAINER_NAME:-dmux-sandbox-dev-run}"

echo "Building ${IMAGE_NAME} from ${ROOT_DIR}/packages/sandbox/Dockerfile"
docker build -t "${IMAGE_NAME}" -f "${ROOT_DIR}/packages/sandbox/Dockerfile" "${ROOT_DIR}"

echo "Starting container ${CONTAINER_NAME} with Docker-in-Docker, buildkit, cmux-sandboxd, and dmux CLI on port ${PORT}"
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

# Build SSH agent forwarding args if SSH_AUTH_SOCK is set and the socket exists
# Mount to /ssh-agent.sock (not /run) to avoid being hidden by --tmpfs /run
# Works with: macOS launchd agent, Docker Desktop, OrbStack
SSH_AGENT_ARGS=""
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -e "${SSH_AUTH_SOCK}" ]; then
  SSH_AGENT_ARGS="-v ${SSH_AUTH_SOCK}:/ssh-agent.sock -e SSH_AUTH_SOCK=/ssh-agent.sock"
  echo "SSH agent forwarding enabled (${SSH_AUTH_SOCK})"
fi

# shellcheck disable=SC2086
docker run --privileged -d \
  --name "${CONTAINER_NAME}" \
  --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --dns 1.1.1.1 --dns 8.8.8.8 \
  -e CMUX_SANDBOX_PORT="${PORT}" \
  -p "${PORT}:${PORT}" \
  -v dmux-sandbox-docker:/var/lib/docker \
  -v dmux-sandbox-data:/var/lib/cmux/sandboxes \
  ${SSH_AGENT_ARGS} \
  --entrypoint /usr/local/bin/bootstrap-dind.sh \
  "${IMAGE_NAME}" \
  /usr/local/bin/cmux-sandboxd --bind 0.0.0.0 --port "${PORT}" --data-dir /var/lib/cmux/sandboxes

echo "Waiting for cmux-sandboxd to be ready on port ${PORT}..."
for i in {1..30}; do
  if curl -s "http://127.0.0.1:${PORT}/healthz" >/dev/null; then
    echo "cmux-sandboxd is up!"
    break
  fi
  sleep 0.5
done

if [ -z "${CMUX_NO_ATTACH:-}" ]; then
  echo "Attaching shell; type 'exit' to leave and 'docker stop ${CONTAINER_NAME}' to stop container"
  docker exec --detach-keys="ctrl-^" -it -e TERM=xterm-256color "${CONTAINER_NAME}" bash -l
else
  echo "Container started in background. Run 'docker exec -it ${CONTAINER_NAME} bash -l' to attach."
fi
