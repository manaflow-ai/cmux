#!/bin/sh
# Copies the shared markdown-viewer web shell (Resources/markdown-viewer) into
# the iOS app bundle and deflate-compresses the JS, matching the macOS app's
# resource layout so MarkdownWebViewerAssets loads identical bytes on both
# platforms. Only the shell's own files ship; the diff-viewer and webviews-app
# React bundles are macOS-only and are excluded.
#
# Xcode user-script sandboxing only permits writing files declared in the
# phase's outputPaths, so compression happens in DERIVED_FILE_DIR scratch and
# each final bundle file is copied (and declared) individually.
set -eu

SRC_DIR="${SRCROOT}/../Resources/markdown-viewer"
DEST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/markdown-viewer"
STAGE_DIR="${DERIVED_FILE_DIR}/markdown-viewer"

if [ ! -d "$SRC_DIR" ]; then
  echo "error: markdown viewer assets not found at $SRC_DIR" >&2
  exit 1
fi

PLAIN_ASSETS="shell.html highlight-github.css highlight-github-dark.css github-markdown.css"
JS_ASSETS="marked.min.js highlight.min.js viewer-navigation.js mermaid.min.js vega.min.js vega-lite.min.js vega-embed.min.js"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$DEST_DIR"

for name in $PLAIN_ASSETS $JS_ASSETS; do
  if [ ! -f "$SRC_DIR/$name" ]; then
    echo "error: missing markdown viewer asset $SRC_DIR/$name" >&2
    exit 1
  fi
  cp "$SRC_DIR/$name" "$STAGE_DIR/$name"
done

"${SRCROOT}/../scripts/compress-markdown-viewer-assets.sh" "$STAGE_DIR"

for name in $PLAIN_ASSETS; do
  cp -f "$STAGE_DIR/$name" "$DEST_DIR/$name"
done
for name in $JS_ASSETS; do
  cp -f "$STAGE_DIR/$name.deflate" "$DEST_DIR/$name.deflate"
done
