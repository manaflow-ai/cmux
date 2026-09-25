#!/usr/bin/env bash
# Remove linker search paths that point at the build machine's toolchain.
# The caller must re-sign the binary after this mutation.
set -euo pipefail

if [[ "$#" -lt 1 ]]; then
  echo "usage: $0 <mach-o>..." >&2
  exit 2
fi

OTOOL_TOOL="${OTOOL_TOOL:-/usr/bin/otool}"
INSTALL_NAME_TOOL="${INSTALL_NAME_TOOL:-/usr/bin/install_name_tool}"
LIPO_TOOL="${LIPO_TOOL:-/usr/bin/lipo}"
for tool in "$OTOOL_TOOL" "$INSTALL_NAME_TOOL" "$LIPO_TOOL"; do
  if [[ ! -x "$tool" ]]; then
    echo "error: required Mach-O tool not found or not executable: $tool" >&2
    exit 1
  fi
done

rpath_is_allowed() {
  case "$1" in
    /usr/lib/swift|@executable_path|@executable_path/*|@loader_path|@loader_path/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

strip_thin_binary() {
  local binary="$1"
  local rpaths
  if ! rpaths="$("$OTOOL_TOOL" -arch all -l "$binary" 2>&1)"; then
    echo "error: could not inspect Mach-O rpaths: $binary" >&2
    echo "$rpaths" >&2
    return 1
  fi
  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    if ! rpath_is_allowed "$rpath"; then
      echo "Removing non-bundled cmux-cua rpath from $binary: $rpath"
      "$INSTALL_NAME_TOOL" -delete_rpath "$rpath" "$binary"
    fi
  done < <(
    printf '%s\n' "$rpaths" | awk '
      $1 == "cmd" {
        command = $2
        next
      }
      command == "LC_RPATH" && $1 == "path" {
        value = $0
        sub(/^[[:space:]]+path[[:space:]]+/, "", value)
        sub(/[[:space:]]+\(offset [0-9]+\).*$/, "", value)
        print value
        command = ""
      }
    ' | sort -u
  )
}

strip_binary() {
  local binary="$1"
  local archs
  local mode
  local scratch
  local arch
  local slice
  local rebuilt
  local -a arch_list
  local -a slices

  if [[ ! -f "$binary" ]]; then
    echo "error: Mach-O binary not found: $binary" >&2
    return 1
  fi

  archs="$("$LIPO_TOOL" -archs "$binary")"
  mode="$(stat -f '%Lp' "$binary")"
  read -r -a arch_list <<<"$archs"
  if [[ "${#arch_list[@]}" -le 1 ]]; then
    strip_thin_binary "$binary"
    return 0
  fi

  scratch="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cua-rpaths.XXXXXX")"
  for arch in "${arch_list[@]}"; do
    slice="$scratch/$arch"
    "$LIPO_TOOL" -thin "$arch" "$binary" -output "$slice"
    strip_thin_binary "$slice"
    slices+=("$slice")
  done
  rebuilt="$scratch/rebuilt"
  "$LIPO_TOOL" -create "${slices[@]}" -output "$rebuilt"
  cp "$rebuilt" "$binary"
  chmod "$mode" "$binary"
  rm -rf "$scratch"
}

for binary in "$@"; do
  strip_binary "$binary"
done
