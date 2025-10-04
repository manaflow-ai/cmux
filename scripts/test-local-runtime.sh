#!/usr/bin/env bash
set -euo pipefail

IMAGE_BASENAME="${1:-cmux-local-sanity}"
OPENVSCODE_URL="http://localhost:39378/?folder=/root/workspace"
FORCE_DIND=${FORCE_DIND:-0}

declare -a ACTIVE_CONTAINERS=()

cleanup_containers() {
  if [[ -z "${ACTIVE_CONTAINERS+x}" ]]; then
    return
  fi

  for container in "${ACTIVE_CONTAINERS[@]}"; do
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$container"; then
      docker rm -f "$container" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup_containers EXIT

platform_slug() {
  local slug="${1//\//-}"
  slug="${slug//:/-}"
  echo "$slug"
}

platform_supported() {
  local platform="$1"
  local probe_image="${PLATFORM_PROBE_IMAGE:-ubuntu:24.04}"

  if docker run --rm --platform "$platform" --entrypoint /bin/true "$probe_image" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

cleanup_container() {
  local container="$1"
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$container"; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
}

remove_active_container() {
  local container="$1"
  for i in "${!ACTIVE_CONTAINERS[@]}"; do
    if [[ "${ACTIVE_CONTAINERS[$i]}" == "$container" ]]; then
      unset 'ACTIVE_CONTAINERS[$i]'
      break
    fi
  done
}

wait_for_openvscode() {
  local container="$1"
  local url="$2"
  local platform="$3"
  echo "[sanity][$platform] Waiting for OpenVSCode to respond..."
  for i in {1..60}; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "[sanity][$platform] OpenVSCode reachable at $url"
      return
    fi
    sleep 1
  done

  echo "[sanity][$platform] ERROR: OpenVSCode did not become ready within 60s" >&2
  docker logs "$container" || true
  exit 1
}

check_unit() {
  local container="$1"
  local unit="$2"
  if ! docker exec "$container" systemctl is-active --quiet "$unit"; then
    echo "[sanity] ERROR: systemd unit $unit is not active" >&2
    docker exec "$container" systemctl status "$unit" || true
    exit 1
  fi
  echo "[sanity] systemd unit $unit is active"
}

HOST_ARCH=$(uname -m)
HOST_PLATFORM=""
case "$HOST_ARCH" in
  x86_64|amd64)
    HOST_PLATFORM="linux/amd64"
    ;;
  arm64|aarch64)
    HOST_PLATFORM="linux/arm64/v8"
    ;;
esac

run_dind_hello_world() {
  local container="$1"
  local platform="$2"

  case "$platform" in
    linux/amd64)
      if [[ "$HOST_ARCH" == "x86_64" || "$HOST_ARCH" == "amd64" ]]; then
        echo "[sanity][$platform] Running DinD hello-world test..."
        docker exec "$container" docker run --rm hello-world >/dev/null
        echo "[sanity][$platform] DinD hello-world succeeded"
      elif [[ "$HOST_ARCH" == "arm64" || "$HOST_ARCH" == "aarch64" ]]; then
        if [[ "$FORCE_DIND" == "1" ]]; then
          echo "[sanity][$platform] Force-running DinD hello-world on arm host (qemu emulation)..."
          docker exec "$container" docker run --rm hello-world >/dev/null
          echo "[sanity][$platform] DinD hello-world succeeded (forced run)"
        else
          echo "[sanity][$platform] Skipping DinD hello-world on host arch $HOST_ARCH (known qemu instability)." >&2
          echo "[sanity][$platform] Set FORCE_DIND=1 to attempt the DinD check under qemu anyway." >&2
        fi
      else
        echo "[sanity][$platform] Skipping DinD hello-world on unsupported host arch $HOST_ARCH." >&2
      fi
      ;;
    linux/arm64*)
      echo "[sanity][$platform] Running DinD hello-world test..."
      docker exec "$container" docker run --rm hello-world >/dev/null
      echo "[sanity][$platform] DinD hello-world succeeded"
      ;;
    *)
      if [[ "$FORCE_DIND" == "1" ]]; then
        echo "[sanity][$platform] Force-running DinD hello-world..."
        docker exec "$container" docker run --rm hello-world >/dev/null
        echo "[sanity][$platform] DinD hello-world succeeded"
      else
        echo "[sanity][$platform] Skipping DinD hello-world on platform $platform. Set FORCE_DIND=1 to force." >&2
      fi
      ;;
  esac
}

run_checks_for_platform() {
  local platform="$1"
  local suffix
  suffix=$(platform_slug "$platform")
  local image_name="${IMAGE_BASENAME}-${suffix}"
  local container_name="cmux-local-sanity-${suffix}"
  local volume_name="cmux-local-docker-${suffix}"

  if ! platform_supported "$platform" && [[ "${FORCE_CROSS_BUILD:-0}" != "1" ]]; then
    echo "[sanity][$platform] Skipping build: platform not runnable on this host (set FORCE_CROSS_BUILD=1 to force)." >&2
    return
  fi

  echo "[sanity][$platform] Building local runtime image ($image_name)..."
  docker build --platform "$platform" -t "$image_name" .

  if [[ -n "$HOST_PLATFORM" && "$platform" != "$HOST_PLATFORM" && "${FORCE_CROSS_RUN:-0}" != "1" ]]; then
    echo "[sanity][$platform] Skipping runtime checks on host arch $HOST_ARCH (set FORCE_CROSS_RUN=1 to force)." >&2
    return
  fi

  remove_active_container "$container_name"
  cleanup_container "$container_name"

  echo "[sanity][$platform] Starting container..."
  docker run -d \
    --rm \
    --privileged \
    --cgroupns=host \
    --tmpfs /run \
    --tmpfs /run/lock \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$volume_name":/var/lib/docker \
    -p 39376:39376 \
    -p 39377:39377 \
    -p 39378:39378 \
    -p 39379:39379 \
    --name "$container_name" \
    "$image_name" >/dev/null

  ACTIVE_CONTAINERS+=("$container_name")

  wait_for_openvscode "$container_name" "$OPENVSCODE_URL" "$platform"

  check_unit "$container_name" cmux-openvscode.service
  check_unit "$container_name" cmux-worker.service

  run_dind_hello_world "$container_name" "$platform"

  cleanup_container "$container_name"
  remove_active_container "$container_name"
}

BUILD_PLATFORMS=("linux/amd64")
if [[ -n "$HOST_PLATFORM" && "$HOST_PLATFORM" != "linux/amd64" ]]; then
  BUILD_PLATFORMS+=("$HOST_PLATFORM")
fi

for platform in "${BUILD_PLATFORMS[@]}"; do
  run_checks_for_platform "$platform"
done

echo "[sanity] All checks passed for platforms: ${BUILD_PLATFORMS[*]}"
