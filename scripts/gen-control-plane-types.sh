#!/usr/bin/env bash
# Generate the control-plane wire types from schemas/control-plane/*.schema.json.
#
# The schemas are the ONLY hand-editable source. Both outputs are committed;
# scripts/check-control-plane-types.sh regenerates and fails CI on any diff,
# so the generated files can never drift from the schemas or be hand-edited.
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
SWIFT_OUT="${1:-Packages/Shared/CmuxIrxTransport/Sources/CmuxIrxTransport/ControlPlane/CtlWireModels.swift}"
TS_OUT="${2:-workers/presence/src/generated/controlPlane.ts}"

mkdir -p "$(dirname "$SWIFT_OUT")" "$(dirname "$TS_OUT")"

"${QT[@]}" --src-lang schema "${SCHEMAS[@]}" \
  --lang swift \
  --struct-or-class struct \
  --access-level public \
  --protocol equatable \
  --no-initializers \
  --out "$SWIFT_OUT"

# CmuxIrxTransport builds with Swift 6 access-level imports: public API using
# Foundation types requires `public import Foundation`.
perl -pi -e 's/^import Foundation$/public import Foundation/' "$SWIFT_OUT"

"${QT[@]}" --src-lang schema "${SCHEMAS[@]}" \
  --lang typescript \
  --just-types \
  --prefer-unions \
  --out "$TS_OUT"

echo "generated: $SWIFT_OUT"
echo "generated: $TS_OUT"
