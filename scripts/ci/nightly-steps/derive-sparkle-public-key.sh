#!/usr/bin/env bash
# nightly.yml build-sign-notarize-nightly and nightly-next-one: "Derive Sparkle public key from private key". Moved out
# of the workflow to keep nightly.yml under its size budget (tests/test_workflow_file_size.py); the step's env: still
# sets every input.
set -euo pipefail
SPARKLE_PRIVATE_KEY="$(./scripts/ci/nightly-sparkle-key.sh)"
DERIVED_PUBLIC_KEY=$(
  printf '%s' "$SPARKLE_PRIVATE_KEY" |
    env -u SPARKLE_PRIVATE_KEY \
      -u SHARED_SPARKLE_PRIVATE_KEY \
      -u NIGHTLY_SPARKLE_PRIVATE_KEY \
      -u NEXT_SPARKLE_PRIVATE_KEY \
      swift scripts/derive_sparkle_public_key.swift --stdin
)
echo "Derived Sparkle public key: $DERIVED_PUBLIC_KEY"
if [ "$TRACK" = "nightly-next" ] && [ "$DERIVED_PUBLIC_KEY" != "$NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY" ]; then
  echo "SPARKLE_NEXT_PRIVATE_KEY does not derive the pinned NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY" >&2
  exit 1
fi
echo "SPARKLE_PUBLIC_KEY=$DERIVED_PUBLIC_KEY" >> "$GITHUB_ENV"
