#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
image="${CMUX_BROKER_IMAGE:-localhost/cmux-agent-broker:staging}"
env_file="${CMUX_BROKER_ENV_FILE:-/etc/cmux/agent-broker-staging.env}"

source_sha="${CMUX_SOURCE_SHA:-$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)}"
if [[ ! "$source_sha" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'build requires CMUX_SOURCE_SHA naming the deployed snapshot\n' >&2
  exit 1
fi
podman build --build-arg "CMUX_SOURCE_SHA=$source_sha" --file "$repo_root/workers/agent-broker/Dockerfile" --tag "$image" "$repo_root"

if [[ "${CMUX_BROKER_INSTALL:-0}" == "1" ]]; then
  if [[ ! -r "$env_file" ]]; then
    printf 'refusing install: missing readable %s\n' "$env_file" >&2
    exit 1
  fi
  sudo install -D -m 0644 "$repo_root/workers/agent-broker/systemd/cmux-agent-broker-staging.service" \
    /etc/systemd/system/cmux-agent-broker-staging.service
  sudo systemctl daemon-reload
  sudo systemctl enable cmux-agent-broker-staging.service
  sudo systemctl restart cmux-agent-broker-staging.service
  sudo systemctl --no-pager --full status cmux-agent-broker-staging.service
else
  printf 'built %s; set CMUX_BROKER_INSTALL=1 to install/restart the staging unit\n' "$image"
fi
