#!/bin/sh
set -eu

MARKDOWN_VIEWER_DIR="${1:-${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/markdown-viewer}"

if [ ! -d "$MARKDOWN_VIEWER_DIR" ]; then
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to compress markdown viewer assets" >&2
  exit 1
fi

python3 - "$MARKDOWN_VIEWER_DIR" <<'PY'
import pathlib
import sys
import zlib

root = pathlib.Path(sys.argv[1])

# Compress top-level JS and CSS assets only. Both are loaded as decompressed
# text via MarkdownViewerAssets.loadAsset (which prefers the .deflate variant),
# so deflating the large CSS (e.g. katex-fonts.min.css with inlined fonts)
# shrinks the bundle without changing runtime behavior. Subdirectory assets
# (diff-viewer/, webviews-app/) are intentionally left untouched.
for path in sorted(root.glob("*.js")) + sorted(root.glob("*.css")):
    raw = path.read_bytes()
    compressor = zlib.compressobj(9, zlib.DEFLATED, -zlib.MAX_WBITS)
    compressed = compressor.compress(raw) + compressor.flush()
    output = path.with_name(path.name + ".deflate")
    output.write_bytes(compressed)
    path.unlink()
    print(f"compressed markdown viewer asset: {path.name} -> {output.name} ({len(raw)} -> {len(compressed)} bytes)")
PY
