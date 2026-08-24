#!/bin/sh
# Copies the shared markdown-viewer web shell (Resources/markdown-viewer) into
# the iOS app bundle and deflate-compresses the JS, matching the macOS app's
# resource layout so MarkdownWebViewerAssets loads identical bytes on both
# platforms. Only the shell's own files ship; the diff-viewer and webviews-app
# React bundles are macOS-only and are excluded.
set -eu

SRC_DIR="${SRCROOT}/../Resources/markdown-viewer"
DEST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/markdown-viewer"

if [ ! -d "$SRC_DIR" ]; then
  echo "error: markdown viewer assets not found at $SRC_DIR" >&2
  exit 1
fi

rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

for name in \
  shell.html \
  marked.min.js \
  highlight.min.js \
  highlight-github.css \
  highlight-github-dark.css \
  github-markdown.css \
  viewer-navigation.js \
  mermaid.min.js \
  vega.min.js \
  vega-lite.min.js \
  vega-embed.min.js
do
  if [ ! -f "$SRC_DIR/$name" ]; then
    echo "error: missing markdown viewer asset $SRC_DIR/$name" >&2
    exit 1
  fi
  cp "$SRC_DIR/$name" "$DEST_DIR/$name"
done

"${SRCROOT}/../scripts/compress-markdown-viewer-assets.sh" "$DEST_DIR"
