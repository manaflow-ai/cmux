#!/usr/bin/env bash
set -euo pipefail

SPARKLE_VERSION="${SPARKLE_VERSION:-2.8.1}"
SPARKLE_KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-cmux}"
SPARKLE_ENV_FILE="${SPARKLE_ENV_FILE:-.env}"

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

echo "Cloning Sparkle ${SPARKLE_VERSION}..."
git clone --depth 1 --branch "$SPARKLE_VERSION" https://github.com/sparkle-project/Sparkle "$work_dir/Sparkle"

echo "Building Sparkle generate_keys tool..."
xcodebuild \
  -project "$work_dir/Sparkle/Sparkle.xcodeproj" \
  -scheme generate_keys \
  -configuration Release \
  -derivedDataPath "$work_dir/build" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

generate_keys="$work_dir/build/Build/Products/Release/generate_keys"
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
