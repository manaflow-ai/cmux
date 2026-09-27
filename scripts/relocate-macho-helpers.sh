#!/usr/bin/env bash
# Move executable Mach-O helpers out of Contents/Resources/bin before signing.
# Shell wrappers and data resources stay in Resources/bin. Compatibility
# symlinks keep the old top-level paths working without embedding Mach-O bytes
# in the resources directory.
set -euo pipefail

usage() {
  echo "usage: $0 <app-path>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
APP_PATH="$1"
CONTENTS_DIR="$APP_PATH/Contents"
RESOURCE_BIN_DIR="$CONTENTS_DIR/Resources/bin"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
FILE_TOOL="${CMUX_FILE_TOOL:-/usr/bin/file}"

[[ -d "$CONTENTS_DIR" ]] || { echo "error: app bundle is missing Contents: $APP_PATH" >&2; exit 1; }
[[ -x "$FILE_TOOL" ]] || { echo "error: file tool is not executable: $FILE_TOOL" >&2; exit 1; }
[[ -d "$RESOURCE_BIN_DIR" ]] || { echo "no Resources/bin directory; nothing to relocate"; exit 0; }

mkdir -p "$HELPERS_DIR"
cli_relocated=0

for source_path in "$RESOURCE_BIN_DIR"/*; do
  [[ -f "$source_path" && ! -L "$source_path" && -x "$source_path" ]] || continue
  if ! "$FILE_TOOL" -b "$source_path" 2>/dev/null | grep -q 'Mach-O'; then
    continue
  fi

  name="$(basename "$source_path")"
  destination_path="$HELPERS_DIR/$name"
  if [[ -e "$destination_path" && ! -L "$destination_path" && ! "$source_path" -ef "$destination_path" ]]; then
    rm -f "$destination_path"
  fi
  if [[ ! -e "$destination_path" ]]; then
    mv "$source_path" "$destination_path"
  fi
  chmod 0755 "$destination_path"
  [[ "$name" == cmux ]] && cli_relocated=1
  echo "relocated Mach-O helper: Contents/Resources/bin/$name -> Contents/Helpers/$name"
done

# SwiftPM's executable resource lookup searches beside the standalone CLI. Keep
# the bundle beside the relocated executable and leave a compatibility symlink
# at the old path for older launchers and diagnostics.
if [[ -x "$HELPERS_DIR/cmux" ]]; then
  cli_relocated=1
fi
if (( cli_relocated )); then
  for source_bundle in "$RESOURCE_BIN_DIR"/*.bundle; do
    [[ -d "$source_bundle" && ! -L "$source_bundle" ]] || continue
    name="$(basename "$source_bundle")"
    destination_bundle="$HELPERS_DIR/$name"
    if [[ -e "$destination_bundle" && ! -L "$destination_bundle" ]]; then
      rm -rf "$destination_bundle"
    fi
    if [[ ! -e "$destination_bundle" ]]; then
      mv "$source_bundle" "$destination_bundle"
    fi
    ln -sfn "../../Helpers/$name" "$source_bundle"
  done
  ln -sfn "../../Helpers/cmux" "$RESOURCE_BIN_DIR/cmux"
fi

for helper_path in "$HELPERS_DIR"/*; do
  [[ -f "$helper_path" && -x "$helper_path" ]] || continue
  if "$FILE_TOOL" -b "$helper_path" 2>/dev/null | grep -q 'Mach-O'; then
    name="$(basename "$helper_path")"
    legacy_path="$RESOURCE_BIN_DIR/$name"
    if [[ ! -e "$legacy_path" || -L "$legacy_path" ]]; then
      ln -sfn "../../Helpers/$name" "$legacy_path"
    fi
    echo "verified Mach-O helper: Contents/Helpers/$name"
  fi
done
