#!/usr/bin/env bash
set -euo pipefail

# Sync the diff-viewer web bundle into the iOS CmuxMobileDiffViewer package.
#
# The iOS read-only diff viewer hosts the SAME React bundle the desktop serves
# (`Resources/markdown-viewer/webviews-app` + the vendored `@pierre/diffs`
# assets in `Resources/markdown-viewer/diff-viewer`), but SwiftPM resources must
# live inside the package, so the bundle is copied into the package's
# `DiffViewerBundle/assets/` with the directory names the generated host HTML
# expects (matching the desktop CLI's `ensureDiffViewerAssets` layout).
#
# Run this after regenerating the desktop bundle with
# `./scripts/build-webviews-app.sh` so the phone never ships a stale viewer.
# Pass `--check` to verify the iOS copy is up to date (used by CI / pre-merge).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SRC_APP="$ROOT/Resources/markdown-viewer/webviews-app"
SRC_PIERRE="$ROOT/Resources/markdown-viewer/diff-viewer"
DEST_ROOT="$ROOT/Packages/CmuxMobileDiffViewer/Sources/CmuxMobileDiffViewer/DiffViewerBundle/assets"
DEST_APP="$DEST_ROOT/cmux-webviews-app"
DEST_PIERRE="$DEST_ROOT/pierre-diffs-1.2.7-trees-1.0.0-beta.4"

if [ ! -d "$SRC_APP" ] || [ ! -d "$SRC_PIERRE" ]; then
  echo "error: desktop diff-viewer bundle missing; run ./scripts/build-webviews-app.sh first" >&2
  exit 1
fi

sync_tree() {
  src="$1"
  dest="$2"
  rm -rf "$dest"
  mkdir -p "$dest"
  # Copy contents (not the source dir itself) into the destination so the
  # destination directory name stays the one the host HTML references.
  cp -R "$src/." "$dest/"
}

if [ "${1:-}" = "--check" ]; then
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  sync_tree "$SRC_APP" "$tmp_dir/cmux-webviews-app"
  sync_tree "$SRC_PIERRE" "$tmp_dir/pierre-diffs-1.2.7-trees-1.0.0-beta.4"
  if ! diff -qr "$tmp_dir/cmux-webviews-app" "$DEST_APP" >/dev/null 2>&1 \
    || ! diff -qr "$tmp_dir/pierre-diffs-1.2.7-trees-1.0.0-beta.4" "$DEST_PIERRE" >/dev/null 2>&1; then
    echo "iOS diff viewer bundle is stale; run ./scripts/sync-ios-diff-viewer-bundle.sh" >&2
    exit 1
  fi
  echo "iOS diff viewer bundle is up to date"
  exit 0
fi

sync_tree "$SRC_APP" "$DEST_APP"
sync_tree "$SRC_PIERRE" "$DEST_PIERRE"
echo "Synced iOS diff viewer bundle into $DEST_ROOT"
