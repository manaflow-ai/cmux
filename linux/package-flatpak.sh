#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_NAME="cmux-linux-x86_64"
STAGING_DIR="$DIST_DIR/$PACKAGE_NAME"
APP_ID="${CMUX_LINUX_FLATPAK_APP_ID:-com.cmuxterm.cmux}"
RUNTIME="${CMUX_LINUX_FLATPAK_RUNTIME:-org.gnome.Platform}"
RUNTIME_VERSION="${CMUX_LINUX_FLATPAK_RUNTIME_VERSION:-46}"
SDK="${CMUX_LINUX_FLATPAK_SDK:-org.gnome.Sdk}"
SOURCE_DIR="$DIST_DIR/cmux-linux-flatpak-source"
BUILD_DIR="$DIST_DIR/cmux-linux-flatpak-build"
REPO_DIR="$DIST_DIR/cmux-linux-flatpak-repo"
MANIFEST_PATH="$DIST_DIR/com.cmuxterm.cmux.flatpak.json"
BUNDLE_PATH="$DIST_DIR/cmux-linux-x86_64.flatpak"
PYTHON_BIN="${CMUX_PYTHON:-python3}"
PACKAGE_PYCACHE_PREFIX="${CMUX_PYTHONPYCACHEPREFIX:-${PYTHONPYCACHEPREFIX:-$DIST_DIR/.pycache}}"

if [ -z "${CMUX_LINUX_SKIP_TARBALL:-}" ]; then
  bash "$ROOT_DIR/linux/package.sh"
fi

if ! command -v flatpak-builder >/dev/null 2>&1; then
  echo "flatpak-builder is required to build the cmux Linux Flatpak bundle" >&2
  exit 1
fi
if ! command -v flatpak >/dev/null 2>&1; then
  echo "flatpak is required to build and validate the cmux Linux Flatpak bundle" >&2
  exit 1
fi
if ! command -v ostree >/dev/null 2>&1; then
  echo "ostree is required to validate the cmux Linux Flatpak bundle" >&2
  exit 1
fi

rm -rf "$SOURCE_DIR" "$BUILD_DIR" "$REPO_DIR" "$MANIFEST_PATH" "$BUNDLE_PATH"
mkdir -p "$SOURCE_DIR"
tar -C "$STAGING_DIR" -cf - . | tar -C "$SOURCE_DIR" -xf -

REMOTE_DAEMON_FLAG=()
if [ -f "$SOURCE_DIR/bin/cmuxd-remote" ]; then
  REMOTE_DAEMON_FLAG=("--remote-daemon-included")
fi

SWIFT_CLI_FLAG=()
if ! head -c 2 "$SOURCE_DIR/bin/cmux" | grep -q '#!'; then
  SWIFT_CLI_FLAG=("--swift-cli-included")
fi
VALIDATOR_FLAGS=()
if [ "${#REMOTE_DAEMON_FLAG[@]}" -gt 0 ]; then
  VALIDATOR_FLAGS+=("--require-remote-daemon")
  VALIDATOR_FLAGS+=("--probe-remote-daemon")
fi
if [ "${#SWIFT_CLI_FLAG[@]}" -gt 0 ]; then
  VALIDATOR_FLAGS+=("--require-swift-cli")
fi

PYTHONPYCACHEPREFIX="$PACKAGE_PYCACHE_PREFIX" "$PYTHON_BIN" "$ROOT_DIR/linux/tools/write_package_manifest.py" \
  "$SOURCE_DIR" \
  --distribution flatpak \
  "${REMOTE_DAEMON_FLAG[@]}" \
  "${SWIFT_CLI_FLAG[@]}"

CMUX_FLATPAK_APP_ID="$APP_ID" \
CMUX_FLATPAK_RUNTIME="$RUNTIME" \
CMUX_FLATPAK_RUNTIME_VERSION="$RUNTIME_VERSION" \
CMUX_FLATPAK_SDK="$SDK" \
CMUX_FLATPAK_SOURCE="$SOURCE_DIR" \
CMUX_FLATPAK_MANIFEST="$MANIFEST_PATH" \
PYTHONPYCACHEPREFIX="$PACKAGE_PYCACHE_PREFIX" "$PYTHON_BIN" - <<'PY'
from __future__ import annotations

import json
import os

manifest = {
    "app-id": os.environ["CMUX_FLATPAK_APP_ID"],
    "runtime": os.environ["CMUX_FLATPAK_RUNTIME"],
    "runtime-version": os.environ["CMUX_FLATPAK_RUNTIME_VERSION"],
    "sdk": os.environ["CMUX_FLATPAK_SDK"],
    "branch": "stable",
    "command": "cmux-linux",
    "finish-args": [
        "--share=ipc",
        "--share=network",
        "--socket=x11",
        "--socket=wayland",
        "--filesystem=home",
    ],
    "modules": [
        {
            "name": "cmux-linux",
            "buildsystem": "simple",
            "build-commands": [
                "mkdir -p /app/bin /app/lib /app/share /app/share/doc/cmux",
                "cp -a bin/. /app/bin/",
                "cp -a lib/. /app/lib/",
                "cp -a share/. /app/share/",
                "cp README.md /app/share/doc/cmux/README.md",
                "chmod 0755 /app/bin/cmux-linux /app/bin/cmux",
                "if [ -f /app/bin/cmuxd-remote ]; then chmod 0755 /app/bin/cmuxd-remote; fi",
            ],
            "sources": [
                {
                    "type": "dir",
                    "path": os.environ["CMUX_FLATPAK_SOURCE"],
                }
            ],
        }
    ],
}

with open(os.environ["CMUX_FLATPAK_MANIFEST"], "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

flatpak-builder --force-clean --repo="$REPO_DIR" "$BUILD_DIR" "$MANIFEST_PATH"
flatpak build-bundle "$REPO_DIR" "$BUNDLE_PATH" "$APP_ID" stable
PYTHONPYCACHEPREFIX="$PACKAGE_PYCACHE_PREFIX" "$PYTHON_BIN" "$ROOT_DIR/linux/tools/validate_package.py" "$BUNDLE_PATH" "${VALIDATOR_FLAGS[@]}"
printf 'Linux Flatpak package: %s\n' "$BUNDLE_PATH"
