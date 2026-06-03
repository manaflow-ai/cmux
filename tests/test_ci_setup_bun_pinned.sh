#!/usr/bin/env bash
# Ensures setup-bun does not resolve "latest" through GitHub tag listing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

while IFS= read -r workflow; do
  while IFS=: read -r line_number _; do
    block="$(sed -n "${line_number},$((line_number + 8))p" "$workflow")"
    if ! grep -Eq 'bun-version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' <<<"$block"; then
      echo "FAIL: $workflow:$line_number setup-bun must pin bun-version to an explicit semver"
      exit 1
    fi
    if grep -Eq 'bun-version:[[:space:]]*latest([[:space:]]|$)' <<<"$block"; then
      echo "FAIL: $workflow:$line_number setup-bun must not use bun-version: latest"
      exit 1
    fi
  done < <(grep -n 'uses: oven-sh/setup-bun@' "$workflow" || true)
done < <(git -C "$ROOT_DIR" ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')

echo "PASS: setup-bun versions are pinned"
