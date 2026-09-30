#!/usr/bin/env bash
# Print the Sparkle EdDSA private key a nightly build embeds and signs with.
#
# NIGHTLY_SPARKLE_KEY=nightly moves the nightly channel onto its own key
# (the NIGHTLY_SPARKLE_PRIVATE_KEY secret), so a machine that signs nightlies
# never holds the key stable releases use. Unset keeps the shared key. The rc
# channel always keeps the shared key.
#
# Installed nightlies accept the switch without a transition build: Sparkle
# allows an update to change its EdDSA key when the app stays code signed with
# the same Apple Developer ID. Never rotate the Developer ID certificate in the
# same build. https://sparkle-project.org/documentation/ ("Rotating signing keys")
#
# Inputs come from the environment: NIGHTLY_SPARKLE_KEY, CHANNEL,
# SHARED_SPARKLE_PRIVATE_KEY, NIGHTLY_SPARKLE_PRIVATE_KEY.
set -euo pipefail

selector="${NIGHTLY_SPARKLE_KEY:-}"
case "$selector" in "" | nightly) ;; *)
  echo "NIGHTLY_SPARKLE_KEY must be unset or nightly, got: $selector" >&2
  exit 1 ;;
esac

if [[ "$selector" == nightly && "${CHANNEL:-}" == nightly ]]; then
  if [[ -z "${NIGHTLY_SPARKLE_PRIVATE_KEY:-}" ]]; then
    echo "NIGHTLY_SPARKLE_KEY=nightly needs the NIGHTLY_SPARKLE_PRIVATE_KEY secret" >&2
    exit 1
  fi
  printf '%s' "$NIGHTLY_SPARKLE_PRIVATE_KEY"
  exit 0
fi

if [[ -z "${SHARED_SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "Missing SPARKLE_PRIVATE_KEY secret" >&2
  exit 1
fi
printf '%s' "$SHARED_SPARKLE_PRIVATE_KEY"
