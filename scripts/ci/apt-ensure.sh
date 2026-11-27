#!/usr/bin/env bash
# Make Debian packages available on a CI Linux runner, installing only the
# ones that are missing.
#
# The cmux-tui tree jobs used to run `sudo apt-get update && sudo apt-get
# install -y ...` unconditionally. That works on Blacksmith and GitHub-hosted
# runners, where the runner user has passwordless sudo, but not on our own
# persistent GCP build lanes: there the runner user has no sudo and every
# package is already installed. Run 44363923089 (2026-11-18): all three build
# legs placed on the owned build pool failed in 15 s at "Install Linux build
# dependencies" with nothing missing.
#
# So: ask dpkg which packages are not installed; with none missing, do nothing.
# Otherwise install just those, with sudo only when the user is not root. When
# no install is possible, fail with an annotation naming the runner and the
# packages to provision on it.
#
# Usage: apt-ensure.sh PACKAGE [PACKAGE ...]
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: apt-ensure.sh PACKAGE [PACKAGE ...]" >&2
  exit 2
fi

fail() {
  echo "::error::[cmux-ci machine: apt-provision] ${RUNNER_NAME:-this runner} is missing $*"
  exit 1
}

missing_packages() {
  local package status
  for package in "$@"; do
    status="$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)"
    [ "$status" = "installed" ] || printf '%s\n' "$package"
  done
}

if ! command -v dpkg-query >/dev/null 2>&1; then
  fail "dpkg-query, so it cannot check for: $*; provision them on that machine"
fi

missing=()
while IFS= read -r package; do missing+=("$package"); done < <(missing_packages "$@")
if [ "${#missing[@]}" -eq 0 ]; then
  echo "apt-ensure: already installed: $*"
  exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
  as_root=()
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  as_root=(sudo -n)
else
  fail "${missing[*]} and $(id -un) has no passwordless sudo to install them; provision them on that machine (apt-get install -y ${missing[*]})"
fi

echo "apt-ensure: installing ${missing[*]}"
export DEBIAN_FRONTEND=noninteractive
${as_root[@]+"${as_root[@]}"} apt-get update || echo "apt-ensure: apt-get update failed; trying the install with the current lists" >&2
${as_root[@]+"${as_root[@]}"} apt-get install -y "${missing[@]}"

still=()
while IFS= read -r package; do still+=("$package"); done < <(missing_packages "${missing[@]}")
if [ "${#still[@]}" -gt 0 ]; then
  fail "${still[*]} after apt-get install; provision them on that machine"
fi
echo "apt-ensure: installed ${missing[*]}"
