#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <wheel-directory> <version>" >&2
}

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

wheel_directory="$1"
version="$2"
if [[ ! -d "$wheel_directory" ]]; then
  echo "PyPI wheel directory does not exist: $wheel_directory" >&2
  exit 1
fi
if [[ -z "$version" ]]; then
  echo "PyPI version must not be empty" >&2
  exit 1
fi

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
reconciler="$script_directory/../bindings/reconcile_registry_artifact.py"
if [[ ! -f "$reconciler" ]]; then
  echo "PyPI reconciler does not exist: $reconciler" >&2
  exit 1
fi

shopt -s nullglob
wheels=("$wheel_directory"/*.whl)
if [[ "${#wheels[@]}" -ne 6 ]]; then
  echo "expected six immutable PyPI wheels, found ${#wheels[@]}" >&2
  exit 1
fi

allowed_arguments=()
for wheel in "${wheels[@]}"; do
  allowed_arguments+=(--allowed-artifact "$wheel")
done

for wheel in "${wheels[@]}"; do
  python3 "$reconciler" check \
    --registry pypi \
    --package cmux \
    --version "$version" \
    --artifact "$wheel" \
    "${allowed_arguments[@]}" \
    --wait-seconds 120 \
    --require-match
done
