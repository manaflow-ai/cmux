#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE="${ROOT}/Native/DiffSidecar/Cargo.toml"
OUTPUT_DIR="${ROOT}/webviews/src/diff/generated"
MODE="${1:-write}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-diff-types.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

TS_RS_EXPORT_DIR="$TEMP_DIR" TS_RS_LARGE_INT=number \
  "$ROOT/scripts/run-diff-sidecar-cargo.sh" run --quiet --locked --manifest-path "$CRATE" --bin generate_types

if [[ "$MODE" == "--check" ]]; then
  diff -ru "$OUTPUT_DIR" "$TEMP_DIR"
  exit 0
fi
if [[ "$MODE" != "write" ]]; then
  echo "usage: $0 [write|--check]" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
rsync -a --delete "$TEMP_DIR/" "$OUTPUT_DIR/"
