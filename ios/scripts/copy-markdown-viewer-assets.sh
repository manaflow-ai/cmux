#!/bin/sh
# Copies the shared markdown-viewer web shell (Resources/markdown-viewer) into
# the iOS app bundle, deflate-compressing the JS to match the macOS app's
# resource layout so MarkdownWebViewerAssets loads identical bytes on both
# platforms. Only the shell's own files ship; the diff-viewer and webviews-app
# React bundles are macOS-only and are excluded.
#
# Xcode user-script sandboxing permits writes only to files declared in the
# phase's outputPaths (no scratch dirs), so every artifact is produced in one
# write directly at its declared destination: plain files are copied, JS is
# zlib-deflated straight from source (same format as
# scripts/compress-markdown-viewer-assets.sh and
# MarkdownViewerAssetCompression.inflate).
set -eu

SRC_DIR="${SRCROOT}/../Resources/markdown-viewer"
DEST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/markdown-viewer"

if [ ! -d "$SRC_DIR" ]; then
  echo "error: markdown viewer assets not found at $SRC_DIR" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to compress markdown viewer assets" >&2
  exit 1
fi

PLAIN_ASSETS="shell.html highlight-github.css highlight-github-dark.css github-markdown.css"
JS_ASSETS="marked.min.js highlight.min.js viewer-navigation.js mermaid.min.js vega.min.js vega-lite.min.js vega-embed.min.js"

for name in $PLAIN_ASSETS $JS_ASSETS; do
  if [ ! -f "$SRC_DIR/$name" ]; then
    echo "error: missing markdown viewer asset $SRC_DIR/$name" >&2
    exit 1
  fi
done

mkdir -p "$DEST_DIR"

for name in $PLAIN_ASSETS; do
  cp -f "$SRC_DIR/$name" "$DEST_DIR/$name"
done

python3 - "$SRC_DIR" "$DEST_DIR" $JS_ASSETS <<'PY'
import pathlib
import sys
import zlib

src = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])

for name in sys.argv[3:]:
    raw = (src / name).read_bytes()
    compressed = zlib.compress(raw, 9)
    (dest / (name + ".deflate")).write_bytes(compressed)
    print(f"compressed markdown viewer asset: {name} ({len(raw)} -> {len(compressed)} bytes)")
PY
