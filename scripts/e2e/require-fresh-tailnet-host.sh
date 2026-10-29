#!/usr/bin/env bash
# Refuse to join the tailnet from a runner that already runs Tailscale.
#
# The iOS e2e jobs join as ephemeral CI nodes (tag:ci, tag:e2e-backend) and log
# out when the job ends. On a host that already has a tailscaled, such as a
# self-hosted fleet Mac mini, that join would re-authenticate the host's own
# node under the CI tag and the logout would then drop it from the tailnet,
# taking its fleet identity, SSH and services with it. One tailscaled per host
# owns the tunnel, so a second CI identity there needs its own userspace
# daemon (docs/ci/ios-e2e.md#runners-that-already-run-tailscale), not this job.
#
# Fails before the join, labeled infra-preflight, so a runner variable pointed
# at the fleet costs one red run instead of a fleet host.
set -euo pipefail

found=""
if pgrep -x tailscaled >/dev/null 2>&1; then
  found="a tailscaled process"
elif pgrep -f 'Tailscale.app|io.tailscale.ipn|IPNExtension' >/dev/null 2>&1; then
  found="the Tailscale app"
elif command -v tailscale >/dev/null 2>&1 && tailscale status --json >/dev/null 2>&1; then
  found="a running Tailscale backend"
fi

if [[ -n "$found" ]]; then
  echo "::error::[infra-preflight] runner $(hostname) already runs Tailscale ($found); joining would replace its tailnet identity. Run this lane on ephemeral runners (docs/ci/ios-e2e.md#runners-that-already-run-tailscale)."
  exit 1
fi
echo "no existing Tailscale on $(hostname); safe to join as an ephemeral CI node"
