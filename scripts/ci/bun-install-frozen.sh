#!/usr/bin/env bash
set -euo pipefail

if bun install --frozen-lockfile; then
  exit 0
fi

echo "bun install failed; clearing Bun cache and retrying once" >&2
bun pm cache rm || true
rm -rf node_modules
bun install --frozen-lockfile --force --no-cache
