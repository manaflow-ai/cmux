#!/usr/bin/env bash
# Regression coverage for scripts/ci/nightly-sparkle-key.sh: which Sparkle key
# a nightly build embeds and signs with.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PICK="$ROOT_DIR/scripts/ci/nightly-sparkle-key.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/nightly.yml"

expect() {
  # expect <want> <selector> <channel> [nightly-key]
  local want="$1" got
  got="$(NIGHTLY_SPARKLE_KEY="$2" CHANNEL="$3" SHARED_SPARKLE_PRIVATE_KEY=shared \
    NIGHTLY_SPARKLE_PRIVATE_KEY="${4-nightly}" "$PICK" 2>/dev/null)" || got="<error>"
  if [ "$got" != "$want" ]; then
    echo "FAIL: selector='$2' channel=$3 picked '$got', want '$want'"
    exit 1
  fi
}

expect shared    ""      nightly
expect nightly   nightly nightly
# The rc channel never moves.
expect shared    nightly rc
# Selecting the nightly key without the secret fails instead of falling back.
expect "<error>" nightly nightly ""
expect "<error>" typo    nightly

if SHARED_SPARKLE_PRIVATE_KEY="" CHANNEL=nightly "$PICK" >/dev/null 2>&1; then
  echo "FAIL: a missing shared key must fail"
  exit 1
fi

# The embedded public key and the appcast signature must come from the same
# helper, so they can never disagree.
if grep -Eq '^ +SPARKLE_PRIVATE_KEY: \$\{\{ secrets\.' "$WORKFLOW"; then
  echo "FAIL: nightly.yml passes SPARKLE_PRIVATE_KEY directly; use scripts/ci/nightly-sparkle-key.sh"
  exit 1
fi
if [ "$(grep -c 'SPARKLE_PRIVATE_KEY="$(./scripts/ci/nightly-sparkle-key.sh)"' "$WORKFLOW")" -ne 2 ]; then
  echo "FAIL: nightly.yml must derive the embedded key and sign the appcast through the helper"
  exit 1
fi

echo "PASS: nightly Sparkle key selection"
