#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

port_for_tag() {
  local tag="$1"
  env -u CMUX_PORT -u PORT -u CMUX_PORT_RANGE -u CMUX_PORT_END \
    ./scripts/reload.sh --tag "$tag" --print-dev-web-env |
    awk -F= '$1 == "CMUX_PORT" { print $2 }'
}

port_ci="$(port_for_tag ci)"
port_feature="$(port_for_tag feat-ios-share-diagnostics)"
port_ci_again="$(port_for_tag ci)"

if [[ "$port_ci" != "$port_ci_again" ]]; then
  echo "FAIL: tagged reload port must be stable for the same tag" >&2
  exit 1
fi

for port in "$port_ci" "$port_feature"; do
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 3800 || port > 4799 )); then
    echo "FAIL: tagged reload port must be in 3800-4799, got $port" >&2
    exit 1
  fi
done

if [[ "$port_ci" == "3777" || "$port_feature" == "3777" ]]; then
  echo "FAIL: tagged reloads must not default to shared port 3777" >&2
  exit 1
fi

if [[ "$port_ci" == "$port_feature" ]]; then
  echo "FAIL: expected sample tags to derive different dev web ports" >&2
  exit 1
fi

override_port="$(
  env -u PORT -u CMUX_PORT_RANGE -u CMUX_PORT_END CMUX_PORT=8123 \
    ./scripts/reload.sh --tag ci --print-dev-web-env |
    awk -F= '$1 == "CMUX_PORT" { print $2 }'
)"
if [[ "$override_port" != "8123" ]]; then
  echo "FAIL: explicit CMUX_PORT must override tagged port derivation" >&2
  exit 1
fi

ambient_env="$(
  env -u CMUX_PORT -u PORT CMUX_PORT_RANGE=10 CMUX_PORT_END=9469 \
    ./scripts/reload.sh --tag ci --print-dev-web-env
)"
ambient_port="$(awk -F= '$1 == "CMUX_PORT" { print $2 }' <<<"$ambient_env")"
ambient_range="$(awk -F= '$1 == "CMUX_PORT_RANGE" { print $2 }' <<<"$ambient_env")"
ambient_end="$(awk -F= '$1 == "CMUX_PORT_END" { print $2 }' <<<"$ambient_env")"
if [[ "$ambient_range" != "1" || "$ambient_end" != "$ambient_port" ]]; then
  echo "FAIL: tag-derived ports must ignore stale ambient range/end values" >&2
  exit 1
fi

echo "PASS: tagged reload ports are stable, isolated, and overridable"
