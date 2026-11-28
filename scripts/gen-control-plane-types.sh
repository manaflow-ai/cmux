#!/usr/bin/env bash
# Generate the control-plane wire types from schemas/control-plane/*.schema.json.
#
# The schemas are the ONLY hand-editable source. The output is committed;
# scripts/check-control-plane-types.sh regenerates and fails CI on any diff,
# so the generated file can never drift from the schemas or be hand-edited.
# (The Swift copy lived in CmuxIrxTransport, which had no consumer and was deleted.)
#
# Determinism: quicktype is pinned to an exact version and all flags live
# here. Same schemas + same version + same flags = byte-identical output.
set -euo pipefail

cd "$(dirname "$0")/.."

QUICKTYPE_VERSION=26.0.0
QT=(bunx "quicktype@${QUICKTYPE_VERSION}")
if ! command -v bunx >/dev/null 2>&1; then
  QT=(npx --yes "quicktype@${QUICKTYPE_VERSION}")
fi

SCHEMAS=(schemas/control-plane/*.schema.json)
TS_OUT="${1:-workers/presence/src/generated/controlPlane.ts}"

mkdir -p "$(dirname "$TS_OUT")"

"${QT[@]}" --src-lang schema "${SCHEMAS[@]}" \
  --lang typescript \
  --just-types \
  --prefer-unions \
  --out "$TS_OUT"

echo "generated: $TS_OUT"
