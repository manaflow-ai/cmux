#!/usr/bin/env bash
set -euo pipefail

COMPONENT="${1:-}"
shift || true

if [[ -z "${COMPONENT}" ]]; then
  echo "usage: docker-mode.sh <dockerd|buildkitd> [args...]" >&2
  exit 1
fi

MODE="${CMUX_DOCKER_MODE:-dind}"
SOCKET="${CMUX_DOCKER_SOCKET:-/var/run/docker.sock}"

normalize_socket() {
  local raw="$1"
  if [[ "${raw}" == unix://* ]]; then
    echo "${raw}"
  else
    echo "unix://${raw}"
  fi
}

if [[ "${MODE}" == "dood" ]]; then
  echo "cmux Docker mode=dood; skipping ${COMPONENT} startup (expecting host socket at ${SOCKET})"
  exit 0
fi

case "${COMPONENT}" in
  dockerd)
    SOCKET="$(normalize_socket "${SOCKET}")"
    exec /usr/local/bin/dockerd --host="${SOCKET}" --storage-driver=overlay2 "$@"
    ;;
  buildkitd)
    exec /usr/local/bin/buildkitd "$@"
    ;;
  *)
    echo "unknown component ${COMPONENT}; expected dockerd or buildkitd" >&2
    exit 1
    ;;
esac
