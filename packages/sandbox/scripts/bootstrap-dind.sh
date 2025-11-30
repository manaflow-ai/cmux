#!/usr/bin/env bash
set -euo pipefail

DOCKER_MODE="${CMUX_DOCKER_MODE:-dind}"
DOCKER_SOCKET="${CMUX_DOCKER_SOCKET:-/var/run/docker.sock}"
LOG_DIR="/var/log/cmux-sandbox"
mkdir -p "${LOG_DIR}"

socket_path() {
  local raw="$1"
  if [[ "${raw}" == unix://* ]]; then
    echo "${raw#unix://}"
  else
    echo "${raw}"
  fi
}

SOCKET_PATH="$(socket_path "${DOCKER_SOCKET}")"
export DOCKER_HOST="unix://${SOCKET_PATH}"

wait_for_socket() {
  # In DooD mode, we expect the host socket to be mounted.
  if [[ "${DOCKER_MODE}" != "dood" ]]; then
    return 0
  fi

  for _ in $(seq 1 20); do
    if [[ -S "${SOCKET_PATH}" ]]; then
      return 0
    fi
    sleep 0.5
  done

  echo "warning: Docker socket ${SOCKET_PATH} not found; DooD mode requires mounting the host socket via CMUX_DOCKER_SOCKET" >&2
}

start_dockerd() {
  if [[ "${DOCKER_MODE}" == "dood" ]]; then
    echo "cmux Docker mode=dood; skipping dockerd/buildkitd startup"
    return
  fi

  if pgrep -x dockerd >/dev/null 2>&1; then
    return
  fi

  echo "starting dockerd (Docker-in-Docker)"
  local host_arg="unix://${SOCKET_PATH}"
  dockerd --host="${host_arg}" --storage-driver=overlay2 \
    --iptables=false >"${LOG_DIR}/dockerd.out" 2>&1 &
}

start_buildkitd() {
  if [[ "${DOCKER_MODE}" == "dood" ]]; then
    return
  fi

  if pgrep -x buildkitd >/dev/null 2>&1; then
    return
  fi

  echo "starting buildkitd"
  buildkitd >"${LOG_DIR}/buildkitd.out" 2>&1 &
}

start_dockerd
start_buildkitd

echo "enabling ip forwarding"
echo 1 > /proc/sys/net/ipv4/ip_forward

echo "setting up nat for cmux sandboxes"
  iptables -t nat -C POSTROUTING -s 10.201.0.0/16 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 10.201.0.0/16 -j MASQUERADE

wait_for_socket

if command -v docker >/dev/null 2>&1; then
  for _ in $(seq 1 20); do
    if docker info >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done

  # In DinD mode, add NAT for Docker bridge network since we run dockerd with --iptables=false
  # to avoid conflicts with outer Docker. This enables containers to reach external networks.
  if [[ "${DOCKER_MODE}" != "dood" ]]; then
    echo "setting up nat for docker bridge network"
    iptables -t nat -C POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
  fi
fi

exec "$@"
