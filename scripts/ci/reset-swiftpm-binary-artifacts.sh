#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <cloned-source-packages-dir>" >&2
  exit 64
fi

SOURCE_PACKAGES_DIR="$1"
ARTIFACTS_DIR="$SOURCE_PACKAGES_DIR/artifacts"

mkdir -p "$SOURCE_PACKAGES_DIR"

if [ -d "$ARTIFACTS_DIR" ]; then
  echo "Clearing restored SwiftPM binary artifacts at $ARTIFACTS_DIR"
  rm -rf "$ARTIFACTS_DIR"
fi
