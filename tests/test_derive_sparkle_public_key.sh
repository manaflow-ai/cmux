#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/derive_sparkle_public_key.swift"

# A fixed, non-secret 32-byte seed. The expected public key is stable and
# exercises the same Ed25519 derivation used by release and nightly signing.
PRIVATE_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
EXPECTED_PUBLIC_KEY="O2onvM62pC1io6jQKm8Nc2UyFXcd4kOmOsBIoYtZ2ik="

actual="$(printf '%s' "$PRIVATE_KEY" | swift "$HELPER" --stdin)"
if [[ "$actual" != "$EXPECTED_PUBLIC_KEY" ]]; then
  echo "FAIL: stdin derivation returned an unexpected Sparkle public key" >&2
  exit 1
fi

if swift "$HELPER" "$PRIVATE_KEY" >/dev/null 2>&1; then
  echo "FAIL: the helper accepted private key material in process arguments" >&2
  exit 1
fi

echo "PASS: Sparkle public key derivation accepts stdin and rejects secret arguments"
