#!/usr/bin/env bash
# Install the small set of packages used by the cmux-tui Linux musl legs.
# Pool images install them as root and publish a marker, so build users never
# need sudo. Hosted runners have no /etc/cmux-ci directory and use the normal
# GitHub-hosted bootstrap fallback.
set -euo pipefail

marker="${CMUX_CI_LINUX_BUILD_DEPS_MARKER:-/etc/cmux-ci/linux-build-deps}"
marker_version="cmux-linux-build-deps-v1"
packages=(binutils clang libclang-dev musl-tools pkg-config)

if [[ -e "$marker" ]]; then
  if [[ ! -f "$marker" ]] || ! printf '%s\n' "$marker_version" "${packages[@]}" | cmp -s - "$marker"; then
    echo "cmux Linux build dependency marker is invalid: $marker" >&2
    exit 1
  fi
  for package in "${packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -Fxq 'install ok installed'; then
      echo "cmux Linux build dependency is missing from the pool image: $package" >&2
      exit 1
    fi
  done
  echo "Linux build dependencies are present in the pool image"
  exit 0
fi

sudo apt-get update
sudo apt-get install -y "${packages[@]}"
