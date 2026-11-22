#!/bin/sh
# Builds the shared TypeScript palette ranker for the native JavaScriptCore bridge.
# The output (gitignored; scripts/cmux-next/build-web-bundles.sh) is a small IIFE with no web or Node dependencies.
#
#   scripts/cmux-next/build-palette-ranker.sh          # rebuild the resource
#   scripts/cmux-next/build-palette-ranker.sh --check  # build into a temp dir only (the sources build)
#   scripts/cmux-next/build-palette-ranker.sh --out DIR  # write DIR/palette-ranker.js
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SRC="$ROOT/webviews/src/palette/ranker-bridge.ts"
OUT_DIR="$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources"
MODE=build
# --out DIR writes palette-ranker.js into DIR instead (build-web-bundles.sh --out-root, checks).
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=--check ;;
    --out)
      [ $# -ge 2 ] || { echo "error: --out needs a directory" >&2; exit 2; }
      case "$2" in /*) OUT_DIR="$2" ;; *) OUT_DIR="$PWD/$2" ;; esac
      shift ;;
    *) echo "usage: $0 [--check] [--out DIR]" >&2; exit 2 ;;
  esac
  shift
done
OUT="$OUT_DIR/palette-ranker.js"
REPAIR_REF="https://github.com/manaflow-ai/cmuxterm-hq/blob/main/REPAIR.md#captures-and-the-fleet"
FAIL_REPORTED=0

fail() {
  FAIL_REPORTED=1
  echo "build-palette-ranker: $1" >&2
  echo "build-palette-ranker: fix: see $REPAIR_REF" >&2
  exit 1
}

command -v bun >/dev/null 2>&1 || fail "bun is required to build the shared palette ranker"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cmux-palette-ranker.XXXXXX")"
cleanup() {
  status=$?
  if [ "$status" -ne 0 ] && [ "$FAIL_REPORTED" -eq 0 ]; then
    echo "build-palette-ranker: fix: see $REPAIR_REF" >&2
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT INT TERM

cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null || fail "webviews dependencies could not be installed"
bun build "$SRC" --target browser --format=iife --outfile "$WORK/palette-ranker.js" >/dev/null || fail "TypeScript palette ranker bundle failed"

if [ "$MODE" = "--check" ]; then
  echo "palette ranker bridge bundle builds"
  exit 0
fi

mkdir -p "$(dirname -- "$OUT")"
cp "$WORK/palette-ranker.js" "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
