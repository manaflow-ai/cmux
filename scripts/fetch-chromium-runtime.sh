#!/usr/bin/env bash
# Downloads an OWL Chromium runtime release from manaflow-ai/chromium and
# installs it under ~/Library/Application Support/cmux/chromium-runtime/<tag>.
# Usage: scripts/fetch-chromium-runtime.sh [release-tag]
# Without a tag, the newest owl-chromium-* release is used. Requires gh.
set -euo pipefail

REPO="manaflow-ai/chromium"
INSTALL_ROOT="${CMUX_CHROMIUM_INSTALL_ROOT:-$HOME/Library/Application Support/cmux/chromium-runtime}"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI is required (https://cli.github.com)" >&2
  exit 1
fi

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  TAG=$(gh release list --repo "$REPO" --limit 20 --json tagName \
    --jq '[.[].tagName | select(startswith("owl-chromium-"))][0] // empty')
  if [[ -z "$TAG" ]]; then
    echo "error: no owl-chromium-* release found in $REPO" >&2
    exit 1
  fi
fi

DEST="$INSTALL_ROOT/$TAG"
if [[ -e "$DEST/libowl_fresh_mojo_runtime.dylib" ]]; then
  echo "already installed: $DEST"
  exit 0
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "downloading $TAG from $REPO..."
gh release download "$TAG" --repo "$REPO" --pattern '*.tar.gz' --pattern '*.tar.gz.sha256' --dir "$WORK_DIR"

ARCHIVE=$(find "$WORK_DIR" -name '*.tar.gz' | head -1)
CHECKSUM_FILE=$(find "$WORK_DIR" -name '*.tar.gz.sha256' | head -1)
if [[ -z "$ARCHIVE" ]]; then
  echo "error: release $TAG has no .tar.gz asset" >&2
  exit 1
fi

if [[ -n "$CHECKSUM_FILE" ]]; then
  echo "verifying sha256..."
  EXPECTED=$(awk '{print $1}' "$CHECKSUM_FILE")
  ACTUAL=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
  if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    echo "error: sha256 mismatch (expected $EXPECTED, got $ACTUAL)" >&2
    exit 1
  fi
else
  echo "warning: no .sha256 asset; skipping checksum verification" >&2
fi

echo "extracting..."
EXTRACT_DIR="$WORK_DIR/extract"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR"

# The archive contains a single top-level runtime directory; install its contents.
RUNTIME_DIR=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 2 -name 'libowl_fresh_mojo_runtime.dylib' -exec dirname {} \; | head -1)
if [[ -z "$RUNTIME_DIR" ]]; then
  echo "error: archive does not contain libowl_fresh_mojo_runtime.dylib" >&2
  exit 1
fi

mkdir -p "$INSTALL_ROOT"
rm -rf "$DEST"
mv "$RUNTIME_DIR" "$DEST"

echo "installed: $DEST"
echo "cmux picks up the newest runtime automatically (Debug menu → Debug Windows → Chromium Browser (Experimental))."
