#!/usr/bin/env bash

# Build the exact iOS reload arguments for an app-RPC release gate. The gate
# owns an isolated Simulator and must never inherit the machine's configured
# default iPhone as a second build target.
iroh_release_gate_set_ios_reload_args() {
  local tag="$1"
  local simulator_name="$2"
  local simulator_id="$3"
  local production="$4"

  IROH_RELEASE_GATE_IOS_RELOAD_ARGS=(
    --tag "$tag"
    --simulator "$simulator_name"
    --simulator-id "$simulator_id"
    --simulator-only
  )
  if [[ "$production" -eq 1 ]]; then
    IROH_RELEASE_GATE_IOS_RELOAD_ARGS+=(--prod-auth)
  fi
  IROH_RELEASE_GATE_IOS_RELOAD_ARGS+=(--no-launch)
}
