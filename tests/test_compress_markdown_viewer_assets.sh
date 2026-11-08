#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/markdown-viewer/chunks" "$TMP_DIR/markdown-viewer/nested"
printf 'const top = "top";\n' > "$TMP_DIR/markdown-viewer/top.js"
printf 'export const chunk = "chunk";\n' > "$TMP_DIR/markdown-viewer/chunks/chunk.mjs"
printf 'already compressed\n' > "$TMP_DIR/markdown-viewer/nested/keep.js.deflate"
printf 'body { color: red; }\n' > "$TMP_DIR/markdown-viewer/style.css"

"$ROOT/scripts/compress-markdown-viewer-assets.sh" "$TMP_DIR/markdown-viewer" >/tmp/cmux-compress-assets.log

for path in \
  "$TMP_DIR/markdown-viewer/top.js" \
  "$TMP_DIR/markdown-viewer/chunks/chunk.mjs"
do
  if [ -e "$path" ]; then
    echo "raw JS asset was not removed: $path" >&2
    exit 1
  fi
done

for path in \
  "$TMP_DIR/markdown-viewer/top.js.deflate" \
  "$TMP_DIR/markdown-viewer/chunks/chunk.mjs.deflate"
do
  if [ ! -s "$path" ]; then
    echo "compressed asset missing or empty: $path" >&2
    exit 1
  fi
done

if [ "$(cat "$TMP_DIR/markdown-viewer/nested/keep.js.deflate")" != "already compressed" ]; then
  echo "existing .deflate asset was rewritten" >&2
  exit 1
fi

python3 - <<'PY' "$TMP_DIR/markdown-viewer"
import pathlib
import sys
import zlib

root = pathlib.Path(sys.argv[1])
assert zlib.decompress((root / "top.js.deflate").read_bytes()) == b'const top = "top";\n'
assert zlib.decompress((root / "chunks/chunk.mjs.deflate").read_bytes()) == b'export const chunk = "chunk";\n'
PY
