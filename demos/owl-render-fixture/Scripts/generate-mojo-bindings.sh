#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-generate}"
REPORT_OUT="${2:-$ROOT/artifacts/generated-bindings/bindings-report.html}"

ARGS=(
    --mojom "$ROOT/Mojo/OwlFresh.mojom"
    --swift-out "$ROOT/Sources/OwlMojoBindingsGenerated/OwlFresh.generated.swift"
    --report-out "$REPORT_OUT"
)

if [[ "$MODE" == "--check" || "$MODE" == "check" ]]; then
    ARGS+=(--check)
elif [[ "$MODE" != "generate" ]]; then
    echo "usage: $0 [generate|check|--check] [report-out]" >&2
    exit 2
fi

swift run OwlMojoBindingsGenerator "${ARGS[@]}"
