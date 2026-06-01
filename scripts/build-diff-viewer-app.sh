#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT/diff-viewer"
OUT_DIR="$ROOT/Resources/markdown-viewer/diff-viewer-app"

if [ "${1:-}" = "--check" ]; then
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  (
    cd "$SRC_DIR"
    bun install --frozen-lockfile
    CMUX_DIFF_VIEWER_OUT_DIR="$tmp_dir" bun run build
  )
  if ! diff -qr "$OUT_DIR" "$tmp_dir" >/tmp/cmux-diff-viewer-app-diff.txt; then
    cat /tmp/cmux-diff-viewer-app-diff.txt >&2
    echo "diff viewer app assets are stale; run ./scripts/build-diff-viewer-app.sh" >&2
    exit 1
  fi
  exit 0
fi

(
  cd "$SRC_DIR"
  bun install --frozen-lockfile
  bun run build
)
