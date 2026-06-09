#!/usr/bin/env bash
set -euo pipefail

attempts="${CMUX_SUBMODULE_RETRY_ATTEMPTS:-5}"
delay_seconds="${CMUX_SUBMODULE_RETRY_DELAY_SECONDS:-10}"
depth="${CMUX_SUBMODULE_DEPTH:-1}"

if ! [[ "$attempts" =~ ^[0-9]+$ ]] || [ "$attempts" -lt 1 ]; then
  echo "CMUX_SUBMODULE_RETRY_ATTEMPTS must be a positive integer" >&2
  exit 2
fi

if ! [[ "$delay_seconds" =~ ^[0-9]+$ ]]; then
  echo "CMUX_SUBMODULE_RETRY_DELAY_SECONDS must be a non-negative integer" >&2
  exit 2
fi

depth_args=()
if [ "$depth" != "0" ]; then
  if ! [[ "$depth" =~ ^[0-9]+$ ]] || [ "$depth" -lt 1 ]; then
    echo "CMUX_SUBMODULE_DEPTH must be 0 or a positive integer" >&2
    exit 2
  fi
  depth_args=(--depth "$depth")
fi

cleanup_partial_submodules() {
  if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
    return
  fi

  git submodule deinit -f --all || true

  git config --file .gitmodules --get-regexp '^submodule\..*\.path$' |
    awk '{ print $2 }' |
    while IFS= read -r path; do
      case "$path" in
        ""|/*|.|..|../*|*/..|*/../*|.git|.git/*)
          echo "Refusing to clean unsafe submodule path: $path" >&2
          exit 1
          ;;
      esac
      rm -rf "$path" ".git/modules/$path"
    done
}

for attempt in $(seq 1 "$attempts"); do
  echo "Initializing submodules, attempt $attempt/$attempts"
  if git submodule sync --recursive &&
     git -c protocol.version=2 submodule update --init --force "${depth_args[@]}" --recursive; then
    exit 0
  else
    status=$?
  fi

  if [ "$attempt" -eq "$attempts" ]; then
    echo "Submodule initialization failed after $attempts attempts" >&2
    exit "$status"
  fi

  echo "::warning::Submodule initialization failed on attempt $attempt, retrying"
  cleanup_partial_submodules
  sleep $((delay_seconds * attempt))
done
