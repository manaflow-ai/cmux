#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /path/to/cmux.app" >&2
  exit 1
fi

APP_PATH="$1"

if [ ! -d "$APP_PATH" ]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

strip_binary() {
  local rel_path="$1"
  shift
  local binary_path="$APP_PATH/$rel_path"
  local before_size
  local after_size

  if [ ! -f "$binary_path" ]; then
    echo "Expected binary not found: $binary_path" >&2
    exit 1
  fi

  before_size="$(stat -f %z "$binary_path")"
  echo "Stripping $rel_path"
  echo "  before: $before_size bytes"
  /usr/bin/strip "$@" "$binary_path"
  after_size="$(stat -f %z "$binary_path")"
  echo "  after:  $after_size bytes"
}

strip_binary "Contents/MacOS/cmux" -rSTx
strip_binary "Contents/Resources/bin/cmux" -rSTx
strip_binary "Contents/Frameworks/libcmux_command_palette_nucleo_ffi.dylib" -x
strip_binary "Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/MacOS/CmuxDockTilePlugin" -x
