#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <app-path-or-nucleo-dylib>" >&2
  exit 2
fi

TARGET="$1"
LIB_NAME="libcmux_command_palette_nucleo_ffi.dylib"

if [[ -d "$TARGET/Contents" ]]; then
  DYLIB="$TARGET/Contents/Frameworks/$LIB_NAME"
else
  DYLIB="$TARGET"
fi

if [[ ! -f "$DYLIB" ]]; then
  echo "error: missing bundled Nucleo FFI library at $DYLIB" >&2
  exit 1
fi

install_names=()
while IFS= read -r install_name; do
  install_names+=("$install_name")
done < <(/usr/bin/otool -D "$DYLIB" | awk 'NF && $0 !~ /:$/ { print $1 }')

if [[ "${#install_names[@]}" -eq 0 ]]; then
  echo "error: could not read install name from $DYLIB" >&2
  exit 1
fi

for install_name in "${install_names[@]}"; do
  if [[ "$install_name" != "@rpath/$LIB_NAME" ]]; then
    echo "error: $LIB_NAME has invalid install name: $install_name" >&2
    echo "expected: @rpath/$LIB_NAME" >&2
    exit 1
  fi
done

if /usr/bin/otool -L "$DYLIB" | awk 'NR > 1 && NF { print $1 }' | grep -E '/Users/runner/work|/Native/CommandPaletteNucleoFFI/target|/target/(aarch64|x86_64)-apple-darwin/' >/dev/null; then
  echo "error: $LIB_NAME contains CI/source-tree absolute load paths" >&2
  /usr/bin/otool -L "$DYLIB" >&2
  exit 1
fi

echo "Nucleo FFI artifact OK: $DYLIB"
