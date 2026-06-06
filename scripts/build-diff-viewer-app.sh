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
  diff_output="$(mktemp)"
  set +e
  diff -qr "$OUT_DIR" "$tmp_dir" >"$diff_output"
  diff_status=$?
  set -e
  if [ "$diff_status" -ne 0 ]; then
    cat "$diff_output" >&2
    rm -f "$diff_output"
    if [ "$diff_status" -eq 1 ]; then
      echo "diff viewer app assets are stale; run ./scripts/build-diff-viewer-app.sh" >&2
      exit 1
    fi
    echo "failed to compare diff viewer assets (diff exit $diff_status)" >&2
    exit 2
  fi
  rm -f "$diff_output"
  exit 0
fi

(
  cd "$SRC_DIR"
  bun install --frozen-lockfile
  bun run build
)
