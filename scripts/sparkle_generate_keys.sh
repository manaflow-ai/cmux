#!/usr/bin/env bash
set -euo pipefail

# The output contains the private update-signing key. Keep both newly created
# files and replacement temporaries private regardless of the caller's umask.
umask 077

SPARKLE_VERSION="${SPARKLE_VERSION:-2.8.1}"
SPARKLE_KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-cmux}"
SPARKLE_ENV_FILE="${SPARKLE_ENV_FILE:-.env}"
SPARKLE_281_TARBALL_SHA256="5cddb7695674ef7704268f38eccaee80e3accbf19e61c1689efff5b6116d85be"

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

if [[ "$SPARKLE_VERSION" != 2.8.1 ]]; then
  echo "Unsupported Sparkle tools version $SPARKLE_VERSION; add and review its release tarball checksum first." >&2
  exit 1
fi

echo "Downloading verified Sparkle ${SPARKLE_VERSION} tools..."
tarball="$work_dir/Sparkle-${SPARKLE_VERSION}.tar.xz"
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
  -o "$tarball" \
  "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
actual_sha="$(shasum -a 256 "$tarball" | awk '{print $1}')"
if [[ "$actual_sha" != "$SPARKLE_281_TARBALL_SHA256" ]]; then
  echo "Sparkle ${SPARKLE_VERSION} tarball checksum mismatch: $actual_sha" >&2
  exit 1
fi
mkdir -p "$work_dir/Sparkle"
tar -xf "$tarball" -C "$work_dir/Sparkle" ./bin

generate_keys="$work_dir/Sparkle/bin/generate_keys"
if [[ ! -x "$generate_keys" ]]; then
  echo "generate_keys binary not found at $generate_keys" >&2
  exit 1
fi

echo "Generating or locating Sparkle keys in keychain (account: $SPARKLE_KEYCHAIN_ACCOUNT)..."
"$generate_keys" --account "$SPARKLE_KEYCHAIN_ACCOUNT"

public_key="$("$generate_keys" --account "$SPARKLE_KEYCHAIN_ACCOUNT" -p)"
private_key_file="$work_dir/sparkle_private_key.txt"
"$generate_keys" --account "$SPARKLE_KEYCHAIN_ACCOUNT" -x "$private_key_file"
private_key="$(cat "$private_key_file")"

if [[ -z "$public_key" || -z "$private_key" ]]; then
  echo "Failed to generate Sparkle keys." >&2
  exit 1
fi

if [[ -f "$SPARKLE_ENV_FILE" ]]; then
  tmp_env="$work_dir/env.tmp"
  awk -F= 'BEGIN {OFS="="}
    $1 == "SPARKLE_PUBLIC_KEY" {next}
    $1 == "SPARKLE_PRIVATE_KEY" {next}
    {print}
  ' "$SPARKLE_ENV_FILE" > "$tmp_env"
  mv "$tmp_env" "$SPARKLE_ENV_FILE"
fi

{
  echo "SPARKLE_PUBLIC_KEY=$public_key"
  echo "SPARKLE_PRIVATE_KEY=$private_key"
} >> "$SPARKLE_ENV_FILE"

echo "Sparkle keys written to $SPARKLE_ENV_FILE"
