#!/usr/bin/env bash
# CI guard: the committed control-plane wire types must be exactly what
# scripts/gen-control-plane-types.sh produces from schemas/control-plane/.
# Fails on drift (hand-edited generated file, or schema change without regen).
set -euo pipefail

cd "$(dirname "$0")/.."

TS_COMMITTED="workers/presence/src/generated/controlPlane.ts"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

./scripts/gen-control-plane-types.sh "$TMP/controlPlane.ts" >/dev/null

fail=0
diff -u "$TS_COMMITTED" "$TMP/controlPlane.ts" || fail=1

if [ "$fail" -ne 0 ]; then
  echo "control-plane types are stale or hand-edited; run ./scripts/gen-control-plane-types.sh" >&2
  exit 1
fi
echo "control-plane types OK"
