#!/usr/bin/env bash
# Guard for scripts that run code from an app bundle (smoke launches, the
# bundled CLI, the diff sidecar handshake).
#
# Source this file, then call `cmux_signing_runtime_guard` before the first
# bundle binary runs. It:
#   1. fails when a CI signing keychain made by scripts/ci/signing-keychain.sh
#      still exists in this job, because bundle code must never run while the
#      signing identity is usable; and
#   2. removes signing and publishing credentials from this script's
#      environment, so the bundle code it starts does not inherit them.
#
# Outside CI (no RUNNER_TEMP and no CMUX_SIGNING_KEYCHAIN_STATE_DIR) step 1
# finds no state and passes, so local runs keep working.

cmux_signing_keychain_state_dir() {
  if [ -n "${CMUX_SIGNING_KEYCHAIN_STATE_DIR:-}" ]; then
    printf '%s\n' "$CMUX_SIGNING_KEYCHAIN_STATE_DIR"
  elif [ -n "${RUNNER_TEMP:-}" ]; then
    printf '%s\n' "$RUNNER_TEMP/cmux-signing-keychain"
  fi
}

# Prints the names of the signing keychains this job still holds.
cmux_signing_keychains_present() {
  local state_dir entry
  state_dir="$(cmux_signing_keychain_state_dir)"
  [ -n "$state_dir" ] && [ -d "$state_dir" ] || return 0
  for entry in "$state_dir"/*.password; do
    [ -e "$entry" ] || continue
    basename "$entry" .password
  done
}

cmux_signing_runtime_guard() {
  local present name
  present="$(cmux_signing_keychains_present)"
  if [ -n "$present" ]; then
    echo "error: a CI signing keychain is still present ($(printf '%s' "$present" | tr '\n' ' ')). Run scripts/ci/signing-keychain.sh delete before this step runs bundle code." >&2
    return 1
  fi
  while IFS= read -r name; do
    case "$name" in
      APPLE_CERTIFICATE_*|ASC_API_*|IOS_DISTRIBUTION_*|IOS_*PROVISIONING_PROFILE*|APPLE_*PROVISIONING_PROFILE*) unset "$name" ;;
      SPARKLE_PRIVATE_KEY|NIGHTLY_SPARKLE_PRIVATE_KEY|SHARED_SPARKLE_PRIVATE_KEY|SPARKLE_NEXT_PRIVATE_KEY) unset "$name" ;;
      CMUX_RELEASE_APP_*|CONTENT_SIGNING_*|CF_R2_*|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID|SENTRY_AUTH_TOKEN) unset "$name" ;;
      GH_TOKEN|GITHUB_TOKEN|ACTIONS_RUNTIME_TOKEN|ACTIONS_ID_TOKEN_REQUEST_*) unset "$name" ;;
    esac
  done < <(compgen -e)
}
