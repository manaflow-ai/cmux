#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_HELPER="$ROOT_DIR/scripts/ghostty-zig-version.sh"

if [[ ! -f "$VERSION_HELPER" ]]; then
  echo "missing shared Ghostty Zig version helper: $VERSION_HELPER" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$VERSION_HELPER"

expected="$(
  sed -nE 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
    "$ROOT_DIR/ghostty/build.zig.zon" | head -1
)"
actual="$(ghostty_minimum_zig_version "$ROOT_DIR")"

if [[ -z "$expected" || "$actual" != "$expected" ]]; then
  echo "Ghostty Zig version mismatch: expected '$expected', helper returned '$actual'" >&2
  exit 1
fi

for consumer in \
  "$ROOT_DIR/scripts/install-zig-ci.sh" \
  "$ROOT_DIR/scripts/build-ghostty-cli-helper.sh"; do
  if ! grep -Fq 'ghostty_minimum_zig_version "$REPO_ROOT"' "$consumer"; then
    echo "$(basename "$consumer") does not use the shared Ghostty Zig version" >&2
    exit 1
  fi
done

echo "PASS: cmux build scripts use Ghostty's declared Zig version ($actual)"
